const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;
const Allocator = std.mem.Allocator;

const Error = struct { code: []const u8, message: []const u8 };

const Value = union(enum) {
    const Self = @This();

    String: []const u8,
    BlobString: []const u8,
    Number: i64,
    Float: f64,
    Boolean: bool,
    Error: Error,
    BlobError: Error,
    Null: bool,
    Array: std.ArrayList(Value),

    pub fn deinit(self: Self) void {
        switch (self) {
            .Array => |value| {
                // deinit all items recursively
                for (value.items) |v| {
                    v.deinit();
                }
                // finally deinit original to avoid segmentation fault error
                value.deinit();
            },
            else => {
                // TODO
            },
        }
    }
};

pub const DecoderError = error{ ExpectedLength, EndOfMessage, InvalidCharacter, ExpectedCRLF, ExpectedEOL, UnhandledMessageType, UnexpectedCharacterAfterNull, InvalidBooleanValue, InternalError };

pub const Decoder = struct {
    const Self = @This();

    msg: []const u8,

    read_position: usize,

    allocator: std.mem.Allocator,

    pub fn init(msg: []const u8, allocator: std.mem.Allocator) Self {
        return Self{ .msg = msg, .read_position = 0, .allocator = allocator };
    }

    pub fn decode(self: *Self) DecoderError!Value {
        return try self.readNext();
    }

    pub fn deinit(_: *Self) void {
        // TODO
    }

    fn peekChar(self: *Self) DecoderError!u8 {
        if (self.read_position >= self.msg.len) {
            return DecoderError.EndOfMessage;
        }
        return self.msg[self.read_position];
    }

    fn readNext(self: *Self) DecoderError!Value {
        if (self.readByte()) |byte| {
            return switch (byte) {
                '+' => try self.decodeString(),
                '$' => try self.decodeBlobString(),
                ':' => try self.decodeInteger(),
                ',' => try self.decodeFloat(),
                '#' => try self.decodeBoolean(),
                '-' => try self.decodeError(),
                '!' => try self.decodeBlobError(),
                '_' => try self.decodeNull(),
                '*' => try self.decodeArray(),
                else => DecoderError.UnhandledMessageType,
            };
        }
        return DecoderError.EndOfMessage;
    }

    fn readByte(self: *Self) ?u8 {
        const msg = self.msg;
        if (self.read_position >= msg.len) {
            return null;
        }
        const char = msg[self.read_position];
        self.read_position += 1;
        return char;
    }

    fn decodeString(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        return Value{ .String = line };
    }

    fn decodeBlobString(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        const bytes = try self.readBytes(length);
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.ExpectedEOL;
        }
        return Value{ .BlobString = bytes };
    }

    fn decodeInteger(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        const integer = std.fmt.parseInt(i64, line, 10) catch |err| switch (err) {
            error.Overflow => return DecoderError.InternalError,
            error.InvalidCharacter => return DecoderError.InvalidCharacter,
        };
        return Value{ .Number = integer };
    }

    fn decodeFloat(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        if (eql(u8, line, "inf")) {
            return Value{ .Float = std.math.inf(f64) };
        } else if (eql(u8, line, "-inf")) {
            return Value{ .Float = -std.math.inf(f64) };
        } else if (eql(u8, line, "nan")) {
            return Value{ .Float = std.math.nan(f64) };
        }
        const float = try std.fmt.parseFloat(f64, line);
        return Value{ .Float = float };
    }

    fn decodeBoolean(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        if (line.len > 1) {
            return DecoderError.InvalidCharacter;
        }

        if (eql(u8, line, "f")) {
            return Value{ .Boolean = false };
        } else if (eql(u8, line, "t")) {
            return Value{ .Boolean = true };
        }
        return DecoderError.InvalidCharacter;
    }

    fn decodeError(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        const error_value = try self.parseError(line);
        return Value{ .Error = error_value };
    }

    fn decodeBlobError(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        const bytes = try self.readBytes(length);
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.ExpectedEOL;
        }
        return Value{ .BlobError = try self.parseError(bytes) };
    }

    fn decodeNull(self: *Self) DecoderError!Value {
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.UnexpectedCharacterAfterNull;
        }
        try self.eatNewLine();
        return Value{ .Null = true };
    }

    fn decodeArray(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        var list = std.ArrayList(Value).init(self.allocator);
        if (length == 0) {
            return Value{ .Array = list };
        }
        for (0..length) |_| {
            const nextValue = try self.readNext();
            list.append(nextValue) catch {
                // TODO better error codes
                return DecoderError.InternalError;
            };
        }
        return Value{ .Array = list };
    }

    fn readBytes(self: *Self, length: usize) DecoderError![]const u8 {
        try self.assertIsEnded();
        const msg = self.msg;
        const read_position = self.read_position;
        const end_position = read_position + length;
        if (end_position > msg.len) {
            return DecoderError.EndOfMessage;
        }
        const value = msg[read_position..end_position];
        self.read_position = end_position;
        return value;
    }

    fn readUntilNewLine(self: *Self) DecoderError![]const u8 {
        try self.assertIsEnded();
        const msg = self.msg;
        const current_position = self.read_position;
        var new_line_index = current_position;
        while (self.read_position < msg.len) : (self.read_position += 1) {
            const char = msg[self.read_position];
            if (char == '\r') {
                new_line_index = self.read_position;
                break;
            }
        }
        if (new_line_index == current_position) {
            return DecoderError.EndOfMessage;
        }
        try self.eatNewLine();
        return msg[current_position..new_line_index];
    }

    fn eatNewLine(self: *Self) DecoderError!void {
        try self.assertIsEnded();
        const current_index = self.read_position;
        const next_two_bytes = self.msg[current_index .. current_index + 2];
        if (!eql(u8, next_two_bytes, "\r\n")) {
            return DecoderError.ExpectedCRLF;
        }
        self.read_position += 2;
    }

    fn assertIsEnded(self: *Self) DecoderError!void {
        if (self.read_position >= self.msg.len) {
            return DecoderError.EndOfMessage;
        }
    }

    fn readLengthLine(self: *Self) DecoderError!usize {
        const nextChar = try self.peekChar();
        if (nextChar < '0' or nextChar > '9') {
            return DecoderError.ExpectedLength;
        }
        const lengthLine = try self.readUntilNewLine();
        const length = std.fmt.parseInt(usize, lengthLine, 10) catch |err| switch (err) {
            error.Overflow => return DecoderError.InternalError,
            error.InvalidCharacter => return DecoderError.InvalidCharacter,
        };
        return length;
    }

    fn parseError(_: *Self, raw: []const u8) DecoderError!Error {
        var error_code_length: usize = 0;
        while (error_code_length < raw.len) : (error_code_length += 1) {
            const char = raw[error_code_length];
            if (char < 'A' or char > 'Z') {
                break;
            }
        }
        return Error{ .code = raw[0..error_code_length], .message = std.mem.trim(u8, raw[error_code_length..], " ") };
    }
};

pub fn decodeFromSlice(allocator: Allocator, msg: []const u8) DecoderError!Value {
    var decoder = Decoder.init(msg, allocator);
    defer decoder.deinit();
    return try decoder.decode();
}

test "decodeFromSlice" {
    const value = try decodeFromSlice(test_allocator, "+OK\r\n");
    defer value.deinit();
    try expect(eql(u8, value.String, "OK"));
}

test "decode simple string" {
    var decoder = Decoder.init("+OK\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.String, "OK"));
}

test "decode blob string" {
    var decoder = Decoder.init("$2\r\nOK\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(eql(u8, value.BlobString, "OK"));
    decoder = Decoder.init("$0\r\n\r\n", test_allocator);
    value = try decoder.decode();
    try expect(eql(u8, value.BlobString, ""));
    decoder = Decoder.init("$adff\r\nOK\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
    decoder = Decoder.init("$2\r\nO\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedEOL);
    };
}

test "decode integer" {
    var decoder = Decoder.init(":100\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(value.Number == 100);
    decoder = Decoder.init(":-100\r\n", test_allocator);
    value = try decoder.decode();
    try expect(value.Number == -100);
}

test "decode float" {
    var decoder = Decoder.init(",2.2\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(value.Float == 2.2);
    decoder = Decoder.init(",-2.2\r\n", test_allocator);
    value = try decoder.decode();
    try expect(value.Float == -2.2);
    decoder = Decoder.init(",inf\r\n", test_allocator);
    value = try decoder.decode();
    try expect(std.math.isInf(value.Float));
    decoder = Decoder.init(",-inf\r\n", test_allocator);
    value = try decoder.decode();
    try expect(std.math.isNegativeInf(value.Float));
    decoder = Decoder.init(",nan\r\n", test_allocator);
    value = try decoder.decode();
    try expect(std.math.isNan(value.Float));
}

test "decode boolean" {
    var decoder = Decoder.init("#t\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(value.Boolean == true);
    decoder = Decoder.init("#f\r\n", test_allocator);
    value = try decoder.decode();
    try expect(value.Boolean == false);
}

test "decode error" {
    var decoder = Decoder.init("-ERR Something went wrong\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(eql(u8, value.Error.code, "ERR"));
    try expect(eql(u8, value.Error.message, "Something went wrong"));
    decoder = Decoder.init("-ERR\r\n", test_allocator);
    value = try decoder.decode();
    try expect(eql(u8, value.Error.code, "ERR"));
    try expect(eql(u8, value.Error.message, ""));
}

test "decode blob error" {
    var decoder = Decoder.init("!24\r\nERR Something went wrong\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(eql(u8, value.BlobError.code, "ERR"));
    try expect(eql(u8, value.BlobError.message, "Something went wrong"));
    decoder = Decoder.init("!3\r\nERR\r\n", test_allocator);
    value = try decoder.decode();
    try expect(eql(u8, value.BlobError.code, "ERR"));
    try expect(eql(u8, value.BlobError.message, ""));
    decoder = Decoder.init("!\r\nERR\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
}

test "decode null" {
    var decoder = Decoder.init("_\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Null);
}

test "unhandled message type" {
    var decoder = Decoder.init("^OK\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.UnhandledMessageType);
    };
}

test "zero length array" {
    var decoder = Decoder.init("*0\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.items.len == 0);
}

test "array of string" {
    var decoder = Decoder.init("*2\r\n+Hello\r\n+World!\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.items.len == 2);
    try expect(eql(u8, value.Array.items[0].String, "Hello"));
    try expect(eql(u8, value.Array.items[1].String, "World!"));
}

test "array of mixed values" {
    var decoder = Decoder.init("*2\r\n+Hello\r\n:100\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.items.len == 2);
    try expect(eql(u8, value.Array.items[0].String, "Hello"));
    try expect(value.Array.items[1].Number == 100);
}

test "array with nested arrays" {
    var decoder = Decoder.init("*2\r\n+Hello\r\n*3\r\n+World!\r\n:100\r\n*1\r\n#t\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.items.len == 2);
    try expect(eql(u8, value.Array.items[0].String, "Hello"));
    try expect(value.Array.items[1].Array.items.len == 3);
    try expect(eql(u8, value.Array.items[1].Array.items[0].String, "World!"));
    try expect(value.Array.items[1].Array.items[1].Number == 100);
    try expect(value.Array.items[1].Array.items[2].Array.items.len == 1);
    try expect(value.Array.items[1].Array.items[2].Array.items[0].Boolean == true);
}
