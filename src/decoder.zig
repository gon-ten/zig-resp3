const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;
const Allocator = std.mem.Allocator;

const Error = struct { code: []const u8, message: []const u8 };

pub const VerbatimStringFormat = enum(u2) { mkd, txt };

const VerbatimString = struct { content: []const u8, format: VerbatimStringFormat };

const Value = union(enum) {
    String: []const u8,
    VerbatimString: VerbatimString,
    BlobString: []const u8,
    Number: i64,
    Float: f64,
    Boolean: bool,
    Error: Error,
    BlobError: Error,
    Null: bool,
    Array: std.ArrayList(Value),
    Map: std.StringHashMap(Value),
    Push: std.ArrayList(Value),
    Set: std.ArrayList(Value),
    Attributes: std.StringHashMap(Value),

    pub fn deinit(self: Value) void {
        switch (self) {
            .Push, .Array, .Set => |value| {
                defer value.deinit();
                for (value.items) |v| {
                    v.deinit();
                }
            },
            .Map, .Attributes => |value| {
                var v = value;
                defer v.deinit();
                var iterator = value.iterator();
                while (iterator.next()) |entry| {
                    entry.value_ptr.deinit();
                }
            },
            else => {
                // TODO
            },
        }
    }
};

pub const DecoderError = error{ ExpectedLength, EndOfMessage, InvalidCharacter, ExpectedCRLF, ExpectedEOL, UnhandledMessageType, UnexpectedCharacterAfterNull, InvalidBooleanValue, InternalError, InvalidVerbatimStringFormat, InvalidCharacterAfterVerbatimFormat, PushExpectedString, PushZeroLength, IllegalPushPosition };

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
        const byte = try self.readByte();
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
            '=' => try self.decodeVerbatimString(),
            '%' => try self.decodeMap(),
            '>' => try self.decodePush(),
            '~' => try self.decodeSet(),
            '|' => try self.decodeAttributes(),
            else => DecoderError.UnhandledMessageType,
        };
    }

    fn readByte(self: *Self) DecoderError!u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn decodeString(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        return Value{ .String = line };
    }

    fn decodeVerbatimString(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();

        if (length == 0) {
            return Value{ .VerbatimString = VerbatimString{ .content = "", .format = VerbatimStringFormat.txt } };
        }

        const formatBytes = try self.readBytes(3);

        const format = blk: {
            if (eql(u8, formatBytes, "mkd")) {
                break :blk VerbatimStringFormat.mkd;
            } else if (eql(u8, formatBytes, "txt")) {
                break :blk VerbatimStringFormat.txt;
            } else {
                return DecoderError.InvalidVerbatimStringFormat;
            }
        };

        var nextByte = try self.readByte();

        if (nextByte != ':') return DecoderError.InvalidCharacterAfterVerbatimFormat;

        const content = try self.readBytes(length - 4);

        nextByte = try self.peekChar();
        if (nextByte != '\r') {
            return DecoderError.ExpectedCRLF;
        }

        return Value{ .VerbatimString = VerbatimString{ .content = content, .format = format } };
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
            const value = try self.readNext();

            switch (value) {
                .Push => {
                    list.deinit();
                    value.deinit();
                    return DecoderError.IllegalPushPosition;
                },
                else => {},
            }

            list.append(value) catch {
                // TODO better error codes
                return DecoderError.InternalError;
            };
        }
        return Value{ .Array = list };
    }

    fn decodePush(self: *Self) DecoderError!Value {
        const array_value = try self.decodeArray();

        if (array_value.Array.items.len == 0) {
            array_value.deinit();
            return DecoderError.PushZeroLength;
        }

        switch (array_value.Array.items[0]) {
            .String => {},
            else => {
                array_value.deinit();
                return DecoderError.PushExpectedString;
            },
        }

        return Value{ .Push = array_value.Array };
    }

    fn decodeSet(self: *Self) DecoderError!Value {
        const array_value = try self.decodeArray();
        return Value{ .Set = array_value.Array };
    }

    fn decodeMap(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        var hashMap = std.StringHashMap(Value).init(self.allocator);
        if (length == 0) {
            return Value{ .Map = hashMap };
        }
        for (0..length) |_| {
            const key = try self.readNext();
            const key_val = blk: {
                switch (key) {
                    .String => |v| break :blk v,
                    else => return DecoderError.InvalidCharacter,
                }
            };

            const value = try self.readNext();

            switch (value) {
                .Push => {
                    hashMap.deinit();
                    value.deinit();
                    return DecoderError.IllegalPushPosition;
                },
                else => {},
            }

            hashMap.put(key_val, value) catch {
                // TODO better error codes
                return DecoderError.InternalError;
            };
        }

        return Value{ .Map = hashMap };
    }

    fn decodeAttributes(self: *Self) DecoderError!Value {
        const map_value = try self.decodeMap();
        return Value{ .Attributes = map_value.Map };
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

test "simple string" {
    var decoder = Decoder.init("+OK\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.String, "OK"));
}

test "simple string with unicode" {
    var decoder = Decoder.init("+OK👻\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.String, "OK👻"));
}

test "blob string" {
    var decoder = Decoder.init("$2\r\nOK\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.BlobString, "OK"));
}

test "blob string with zero length" {
    var decoder = Decoder.init("$0\r\n\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.BlobString, ""));
}

test "blob string with invalid length" {
    var decoder = Decoder.init("$adff\r\nOK\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
}

test "blob string with length but message length does not match" {
    var decoder = Decoder.init("$2\r\nO\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedEOL);
    };
}

test "integer positive" {
    var decoder = Decoder.init(":100\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Number == 100);
}

test "integer negative" {
    var decoder = Decoder.init(":-100\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Number == -100);
}

test "float positive" {
    var decoder = Decoder.init(",2.2\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Float == 2.2);
}

test "float negative" {
    var decoder = Decoder.init(",-2.2\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Float == -2.2);
}

test "float positive infinite" {
    var decoder = Decoder.init(",inf\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(std.math.isInf(value.Float));
}

test "float negative infinite" {
    var decoder = Decoder.init(",-inf\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(std.math.isNegativeInf(value.Float));
}

test "float nan" {
    var decoder = Decoder.init(",nan\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(std.math.isNan(value.Float));
}

test "boolean thruty" {
    var decoder = Decoder.init("#f\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Boolean == false);
}

test "boolean falsy" {
    var decoder = Decoder.init("#f\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Boolean == false);
}

test "error" {
    var decoder = Decoder.init("-ERR Something went wrong\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.Error.code, "ERR"));
    try expect(eql(u8, value.Error.message, "Something went wrong"));
}

test "error with no message" {
    var decoder = Decoder.init("-ERR\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.Error.code, "ERR"));
    try expect(eql(u8, value.Error.message, ""));
}

test "blob error" {
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

test "blob error with no message" {
    var decoder = Decoder.init("!3\r\nERR\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.BlobError.code, "ERR"));
    try expect(eql(u8, value.BlobError.message, ""));
}

test "blob error with no length" {
    var decoder = Decoder.init("!\r\nERR\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
}

test "null" {
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

test "array zero length" {
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

test "array with push type inside" {
    var decoder = Decoder.init("*2\r\n+key\r\n>1\r\n+get\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.IllegalPushPosition);
    };
}

test "verbatim string" {
    var decoder = Decoder.init("=15\r\ntxt:Some string\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.VerbatimString.content, "Some string"));
    try expect(value.VerbatimString.format == .txt);
}

test "verbatim string with mkd format" {
    var decoder = Decoder.init("=19\r\nmkd:**Some string**\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.VerbatimString.content, "**Some string**"));
    try expect(value.VerbatimString.format == .mkd);
}

test "verbatim string with invalid format" {
    var decoder = Decoder.init("=19\r\nmd:**Some string**\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.InvalidVerbatimStringFormat);
    };
}

test "verbatim string with invalid length" {
    var decoder = Decoder.init("=5\r\ntxt:Some string\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedCRLF);
    };
}

test "verbatim string with zero length" {
    var decoder = Decoder.init("=0\r\n\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.VerbatimString.content, ""));
    try expect(value.VerbatimString.format == .txt);
}

test "verbatim string with format but content is empty" {
    var decoder = Decoder.init("=4\r\ntxt:\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.VerbatimString.content, ""));
    try expect(value.VerbatimString.format == .txt);
}

test "verbatim string with length but message is larger" {
    var decoder = Decoder.init("=15\r\ntxt:Some string Some string\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedCRLF);
    };
}

test "map basic" {
    var decoder = Decoder.init("%2\r\n+key1\r\n+value1\r\n+key2\r\n+value2\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(eql(u8, value.Map.get("key1").?.String, "value1"));
    try expect(eql(u8, value.Map.get("key2").?.String, "value2"));
}

test "map basic multiple types" {
    var decoder = Decoder.init("%2\r\n+number\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Map.get("number").?.Number == 100);
    try expect(eql(u8, value.Map.get("string").?.String, "value"));
}

test "map with invalid key type" {
    var decoder = Decoder.init("%2\r\n:100\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.InvalidCharacter);
    };
}

test "map with key but not value" {
    var decoder = Decoder.init("%2\r\n+key\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.EndOfMessage);
    };
}

test "map with aggregates" {
    var decoder = Decoder.init("%1\r\n+array\r\n*1\r\n#t\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Map.get("array").?.Array.items.len == 1);
    try expect(value.Map.get("array").?.Array.items[0].Boolean == true);
}

test "map with push type inside" {
    var decoder = Decoder.init("%1\r\n+key\r\n>1\r\n+get\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.IllegalPushPosition);
    };
}

test "attributes basic" {
    var decoder = Decoder.init("|2\r\n+key1\r\n+value1\r\n+key2\r\n+value2\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(eql(u8, value.Attributes.get("key1").?.String, "value1"));
    try expect(eql(u8, value.Attributes.get("key2").?.String, "value2"));
}

test "attributes basic multiple types" {
    var decoder = Decoder.init("|2\r\n+number\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Attributes.get("number").?.Number == 100);
    try expect(eql(u8, value.Attributes.get("string").?.String, "value"));
}

test "attributes with invalid key type" {
    var decoder = Decoder.init("|2\r\n:100\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.InvalidCharacter);
    };
}

test "attributes with key but not value" {
    var decoder = Decoder.init("|2\r\n+key\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.EndOfMessage);
    };
}

test "attributes with aggregates" {
    var decoder = Decoder.init("|1\r\n+array\r\n*1\r\n#t\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Attributes.get("array").?.Array.items.len == 1);
    try expect(value.Attributes.get("array").?.Array.items[0].Boolean == true);
}

test "set zero length" {
    var decoder = Decoder.init("~0\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.items.len == 0);
}

test "set of string" {
    var decoder = Decoder.init("~2\r\n+Hello\r\n+World!\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.items.len == 2);
    try expect(eql(u8, value.Set.items[0].String, "Hello"));
    try expect(eql(u8, value.Set.items[1].String, "World!"));
}

test "set of mixed values" {
    var decoder = Decoder.init("~2\r\n+Hello\r\n:100\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.items.len == 2);
    try expect(eql(u8, value.Set.items[0].String, "Hello"));
    try expect(value.Set.items[1].Number == 100);
}

test "set with nested arrays" {
    var decoder = Decoder.init("~2\r\n+Hello\r\n*3\r\n+World!\r\n:100\r\n*1\r\n#t\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.items.len == 2);
    try expect(eql(u8, value.Set.items[0].String, "Hello"));
    try expect(value.Set.items[1].Array.items.len == 3);
    try expect(eql(u8, value.Set.items[1].Array.items[0].String, "World!"));
    try expect(value.Set.items[1].Array.items[1].Number == 100);
    try expect(value.Set.items[1].Array.items[2].Array.items.len == 1);
    try expect(value.Set.items[1].Array.items[2].Array.items[0].Boolean == true);
}

test "push zero length" {
    var decoder = Decoder.init(">0\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.PushZeroLength);
    };
}

test "push of string" {
    var decoder = Decoder.init(">2\r\n+Hello\r\n+World!\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Push.items.len == 2);
    try expect(eql(u8, value.Push.items[0].String, "Hello"));
    try expect(eql(u8, value.Push.items[1].String, "World!"));
}

test "push first position is not a string" {
    var decoder = Decoder.init(">2\r\n:100\r\n:100\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.PushExpectedString);
    };
}
