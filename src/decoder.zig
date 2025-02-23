const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const expect = std.testing.expect;
const test_allocator = std.testing.allocator;
const Allocator = std.mem.Allocator;

const Error = struct { code: []const u8, message: []const u8 };

pub const VerbatimStringFormat = enum(u2) { mkd, txt };

const VerbatimString = struct { content: []const u8, format: VerbatimStringFormat };

fn GenDataType(comptime T: type) type {
    return struct {
        v: T,
        deep: u8 = 0,
    };
}

const Metadata = struct {
    name: []const u8,
    deep: u8,
};

const Value = union(enum) {
    String: GenDataType([]const u8),
    VerbatimString: GenDataType(VerbatimString),
    BlobString: GenDataType([]const u8),
    Number: GenDataType(i64),
    Float: GenDataType(f64),
    Boolean: GenDataType(bool),
    Error: GenDataType(Error),
    BlobError: GenDataType(Error),
    Null: GenDataType(bool),
    Array: GenDataType(std.ArrayList(Value)),
    Map: GenDataType(std.StringHashMap(Value)),
    Push: GenDataType(std.ArrayList(Value)),
    Set: GenDataType(std.ArrayList(Value)),
    Attribute: GenDataType(std.StringHashMap(Value)),

    pub fn deinit(self: Value) void {
        switch (self) {
            .Push, .Array, .Set => |v| {
                defer v.v.deinit();
                for (v.v.items) |value| {
                    value.deinit();
                }
            },
            .Map, .Attribute => |value| {
                var v = value;
                defer v.v.deinit();
                var iterator = value.v.iterator();
                while (iterator.next()) |entry| {
                    entry.value_ptr.deinit();
                }
            },
            else => {
                // TODO
            },
        }
    }

    fn getMetadata(self: Value) Metadata {
        return switch (self) {
            .String => |v| Metadata{ .name = "String", .deep = v.deep },
            .VerbatimString => |v| Metadata{ .name = "VerbatimString", .deep = v.deep },
            .BlobString => |v| Metadata{ .name = "BlobString", .deep = v.deep },
            .Number => |v| Metadata{ .name = "Number", .deep = v.deep },
            .Float => |v| Metadata{ .name = "Float", .deep = v.deep },
            .Boolean => |v| Metadata{ .name = "Boolean", .deep = v.deep },
            .Error => |v| Metadata{ .name = "Error", .deep = v.deep },
            .BlobError => |v| Metadata{ .name = "BlobError", .deep = v.deep },
            .Null => |v| Metadata{ .name = "Null", .deep = v.deep },
            .Array => |v| Metadata{ .name = "Array", .deep = v.deep },
            .Push => |v| Metadata{ .name = "Push", .deep = v.deep },
            .Set => |v| Metadata{ .name = "Set", .deep = v.deep },
            .Map => |v| Metadata{ .name = "Map", .deep = v.deep },
            .Attribute => |v| Metadata{ .name = "Attribute", .deep = v.deep },
        };
    }

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        const metadata = self.getMetadata();
        const deep = metadata.deep;

        try indent(writer, 0);
        try writer.print("Value.{s} {s}", .{ metadata.name, "{" });

        switch (self) {
            .String, .BlobString => |v| {
                try writer.print(" \"{s}\" ", .{v.v});
            },
            .VerbatimString => |v| {
                try writer.print(" format: {any}, content: \"{s}\" ", .{ v.v.format, v.v.content });
            },
            .Number => |v| {
                try writer.print(" {d} ", .{v.v});
            },
            .Float => |v| {
                try writer.print(" {d} ", .{v.v});
            },
            .Boolean => |v| {
                try writer.print(" {s} ", .{if (v.v) "true" else "false"});
            },
            .Error, .BlobError => |v| {
                try writer.print(" code: \"{s}\", message: \"{s}\" ", .{ v.v.code, v.v.message });
            },
            .Null => {
                try writer.writeAll("null");
            },
            .Array, .Set, .Push => |v| {
                try writer.writeAll("\n");
                for (v.v.items) |item| {
                    try indent(writer, deep + 1);
                    try writer.print("{any},\n", .{item});
                }
                try indent(writer, deep);
            },
            .Map, .Attribute => |v| {
                try writer.writeAll("\n");
                var iterator = v.v.iterator();
                while (iterator.next()) |entry| {
                    try indent(writer, deep + 1);
                    try writer.print("\"{s}\" => {any},\n", .{ entry.key_ptr.*, entry.value_ptr });
                }
                try indent(writer, deep);
            },
        }

        try writer.writeAll("}");
    }
};

fn newLine(writer: anytype, indentLength: u8) !void {
    try writer.writeAll("\n");
    try indent(writer, indentLength);
}

fn indent(writer: anytype, length: u8) !void {
    for (0..length) |_| {
        try writer.writeAll("  ");
    }
}

pub const DecoderError = error{ ExpectedLength, EndOfMessage, InvalidCharacter, ExpectedCRLF, ExpectedEOL, UnexpectedCharacterAfterNull, InvalidBooleanValue, InternalError, InvalidVerbatimStringFormat, InvalidCharacterAfterVerbatimFormat, PushExpectedString, PushZeroLength, IllegalPushPosition, Unsupported };

pub const Decoder = struct {
    const Self = @This();

    msg: []const u8,

    read_position: usize,

    current_deep: u8 = 0,

    allocator: std.mem.Allocator,

    pub fn init(msg: []const u8, allocator: std.mem.Allocator) Self {
        return Self{ .msg = msg, .read_position = 0, .allocator = allocator, .current_deep = 0 };
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
            '|' => try self.decodeAttribute(),
            ')' => {
                // TODO Big int support
                return DecoderError.Unsupported;
            },
            else => DecoderError.Unsupported,
        };
    }

    fn readByte(self: *Self) DecoderError!u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn decodeString(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        return Value{ .String = .{ .v = line, .deep = self.current_deep } };
    }

    fn decodeVerbatimString(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();

        if (length == 0) {
            return Value{ .VerbatimString = .{ .v = VerbatimString{ .content = "", .format = VerbatimStringFormat.txt }, .deep = self.current_deep } };
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

        const nextTwoBytes = try self.readBytes(2);
        if (!eql(u8, nextTwoBytes, "\r\n")) {
            return DecoderError.ExpectedCRLF;
        }

        return Value{ .VerbatimString = .{ .v = VerbatimString{ .content = content, .format = format }, .deep = self.current_deep } };
    }

    fn decodeBlobString(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        const bytes = try self.readBytes(length);
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.ExpectedEOL;
        }
        return Value{ .BlobString = .{ .v = bytes, .deep = self.current_deep } };
    }

    fn decodeInteger(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        const integer = std.fmt.parseInt(i64, line, 10) catch |err| switch (err) {
            error.Overflow => return DecoderError.InternalError,
            error.InvalidCharacter => return DecoderError.InvalidCharacter,
        };
        return Value{ .Number = .{ .v = integer, .deep = self.current_deep } };
    }

    fn decodeFloat(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        if (eql(u8, line, "inf")) {
            return Value{ .Float = .{ .v = std.math.inf(f64), .deep = self.current_deep } };
        } else if (eql(u8, line, "-inf")) {
            return Value{ .Float = .{ .v = -std.math.inf(f64), .deep = self.current_deep } };
        } else if (eql(u8, line, "nan")) {
            return Value{ .Float = .{ .v = std.math.nan(f64), .deep = self.current_deep } };
        }
        const float = try std.fmt.parseFloat(f64, line);
        return Value{ .Float = .{ .v = float, .deep = self.current_deep } };
    }

    fn decodeBoolean(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        if (line.len > 1) {
            return DecoderError.InvalidCharacter;
        }

        if (eql(u8, line, "f")) {
            return Value{ .Boolean = .{ .v = false, .deep = self.current_deep } };
        } else if (eql(u8, line, "t")) {
            return Value{ .Boolean = .{ .v = true, .deep = self.current_deep } };
        }
        return DecoderError.InvalidCharacter;
    }

    fn decodeError(self: *Self) DecoderError!Value {
        const line = try self.readUntilNewLine();
        const error_value = try self.parseError(line);
        return Value{ .Error = .{ .v = error_value, .deep = self.current_deep } };
    }

    fn decodeBlobError(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        const bytes = try self.readBytes(length);
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.ExpectedEOL;
        }
        return Value{ .BlobError = .{ .v = try self.parseError(bytes), .deep = self.current_deep } };
    }

    fn decodeNull(self: *Self) DecoderError!Value {
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.UnexpectedCharacterAfterNull;
        }
        try self.eatNewLine();
        return Value{ .Null = .{ .v = true, .deep = self.current_deep } };
    }

    fn decodeArray(self: *Self) DecoderError!Value {
        const length = try self.readLengthLine();
        var list = std.ArrayList(Value).init(self.allocator);

        self.current_deep += 1;

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

        self.current_deep -= 1;

        return Value{ .Array = .{ .v = list, .deep = self.current_deep } };
    }

    fn decodePush(self: *Self) DecoderError!Value {
        const array_value = try self.decodeArray();

        if (array_value.Array.v.items.len == 0) {
            array_value.deinit();
            return DecoderError.PushZeroLength;
        }

        switch (array_value.Array.v.items[0]) {
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
        self.current_deep += 1;
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

            hashMap.put(key_val.v, value) catch {
                // TODO better error codes
                return DecoderError.InternalError;
            };
        }

        self.current_deep -= 1;

        return Value{ .Map = .{ .v = hashMap, .deep = self.current_deep } };
    }

    fn decodeAttribute(self: *Self) DecoderError!Value {
        const map_value = try self.decodeMap();
        return Value{ .Attribute = map_value.Map };
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
    try expect(eql(u8, value.String.v, "OK"));
}

test "simple string" {
    var decoder = Decoder.init("+OK\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.String.v, "OK"));
}

test "simple string with unicode" {
    var decoder = Decoder.init("+OK👻\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.String.v, "OK👻"));
}

test "blob string" {
    var decoder = Decoder.init("$2\r\nOK\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.BlobString.v, "OK"));
}

test "blob string with zero length" {
    var decoder = Decoder.init("$0\r\n\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.BlobString.v, ""));
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
    try expect(value.Number.v == 100);
}

test "integer negative" {
    var decoder = Decoder.init(":-100\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Number.v == -100);
}

test "float positive" {
    var decoder = Decoder.init(",2.2\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Float.v == 2.2);
}

test "float negative" {
    var decoder = Decoder.init(",-2.2\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Float.v == -2.2);
}

test "float positive infinite" {
    var decoder = Decoder.init(",inf\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(std.math.isInf(value.Float.v));
}

test "float negative infinite" {
    var decoder = Decoder.init(",-inf\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(std.math.isNegativeInf(value.Float.v));
}

test "float nan" {
    var decoder = Decoder.init(",nan\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(std.math.isNan(value.Float.v));
}

test "boolean thruty" {
    var decoder = Decoder.init("#f\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Boolean.v == false);
}

test "boolean falsy" {
    var decoder = Decoder.init("#f\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(value.Boolean.v == false);
}

test "error" {
    var decoder = Decoder.init("-ERR Something went wrong\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.Error.v.code, "ERR"));
    try expect(eql(u8, value.Error.v.message, "Something went wrong"));
}

test "error with no message" {
    var decoder = Decoder.init("-ERR\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.Error.v.code, "ERR"));
    try expect(eql(u8, value.Error.v.message, ""));
}

test "blob error" {
    var decoder = Decoder.init("!24\r\nERR Something went wrong\r\n", test_allocator);
    var value = try decoder.decode();
    try expect(eql(u8, value.BlobError.v.code, "ERR"));
    try expect(eql(u8, value.BlobError.v.message, "Something went wrong"));
    decoder = Decoder.init("!3\r\nERR\r\n", test_allocator);
    value = try decoder.decode();
    try expect(eql(u8, value.BlobError.v.code, "ERR"));
    try expect(eql(u8, value.BlobError.v.message, ""));
    decoder = Decoder.init("!\r\nERR\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
}

test "blob error with no message" {
    var decoder = Decoder.init("!3\r\nERR\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.BlobError.v.code, "ERR"));
    try expect(eql(u8, value.BlobError.v.message, ""));
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
    try expect(value.Null.v);
}

test "unsupported message type" {
    var decoder = Decoder.init("^OK\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.Unsupported);
    };
}

test "array zero length" {
    var decoder = Decoder.init("*0\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.v.items.len == 0);
}

test "array of string" {
    var decoder = Decoder.init("*2\r\n+Hello\r\n+World!\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.v.items.len == 2);
    try expect(eql(u8, value.Array.v.items[0].String.v, "Hello"));
    try expect(eql(u8, value.Array.v.items[1].String.v, "World!"));
}

test "array of mixed values" {
    var decoder = Decoder.init("*2\r\n+Hello\r\n:100\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.v.items.len == 2);
    try expect(eql(u8, value.Array.v.items[0].String.v, "Hello"));
    try expect(value.Array.v.items[1].Number.v == 100);
}

test "array with nested arrays" {
    var decoder = Decoder.init("*2\r\n+Hello\r\n*3\r\n+World!\r\n:100\r\n*1\r\n#t\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Array.v.items.len == 2);
    try expect(eql(u8, value.Array.v.items[0].String.v, "Hello"));
    try expect(value.Array.v.items[1].Array.v.items.len == 3);
    try expect(eql(u8, value.Array.v.items[1].Array.v.items[0].String.v, "World!"));
    try expect(value.Array.v.items[1].Array.v.items[1].Number.v == 100);
    try expect(value.Array.v.items[1].Array.v.items[2].Array.v.items.len == 1);
    try expect(value.Array.v.items[1].Array.v.items[2].Array.v.items[0].Boolean.v == true);
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
    try expect(eql(u8, value.VerbatimString.v.content, "Some string"));
    try expect(value.VerbatimString.v.format == .txt);
}

test "verbatim string with mkd format" {
    var decoder = Decoder.init("=19\r\nmkd:**Some string**\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.VerbatimString.v.content, "**Some string**"));
    try expect(value.VerbatimString.v.format == .mkd);
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
    try expect(eql(u8, value.VerbatimString.v.content, ""));
    try expect(value.VerbatimString.v.format == .txt);
}

test "verbatim string with format but content is empty" {
    var decoder = Decoder.init("=4\r\ntxt:\r\n", test_allocator);
    const value = try decoder.decode();
    try expect(eql(u8, value.VerbatimString.v.content, ""));
    try expect(value.VerbatimString.v.format == .txt);
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
    try expect(eql(u8, value.Map.v.get("key1").?.String.v, "value1"));
    try expect(eql(u8, value.Map.v.get("key2").?.String.v, "value2"));
}

test "map basic multiple types" {
    var decoder = Decoder.init("%2\r\n+number\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Map.v.get("number").?.Number.v == 100);
    try expect(eql(u8, value.Map.v.get("string").?.String.v, "value"));
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
    try expect(value.Map.v.get("array").?.Array.v.items.len == 1);
    try expect(value.Map.v.get("array").?.Array.v.items[0].Boolean.v == true);
}

test "map with push type inside" {
    var decoder = Decoder.init("%1\r\n+key\r\n>1\r\n+get\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.IllegalPushPosition);
    };
}

test "attribute basic" {
    var decoder = Decoder.init("|2\r\n+key1\r\n+value1\r\n+key2\r\n+value2\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(eql(u8, value.Attribute.v.get("key1").?.String.v, "value1"));
    try expect(eql(u8, value.Attribute.v.get("key2").?.String.v, "value2"));
}

test "attribute basic multiple types" {
    var decoder = Decoder.init("|2\r\n+number\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Attribute.v.get("number").?.Number.v == 100);
    try expect(eql(u8, value.Attribute.v.get("string").?.String.v, "value"));
}

test "attribute with invalid key type" {
    var decoder = Decoder.init("|2\r\n:100\r\n:100\r\n+string\r\n+value\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.InvalidCharacter);
    };
}

test "attribute with key but not value" {
    var decoder = Decoder.init("|2\r\n+key\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.EndOfMessage);
    };
}

test "attribute with aggregates" {
    var decoder = Decoder.init("|1\r\n+array\r\n*1\r\n#t\r\n", test_allocator);
    var value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Attribute.v.get("array").?.Array.v.items.len == 1);
    try expect(value.Attribute.v.get("array").?.Array.v.items[0].Boolean.v == true);
}

test "set zero length" {
    var decoder = Decoder.init("~0\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.v.items.len == 0);
}

test "set of string" {
    var decoder = Decoder.init("~2\r\n+Hello\r\n+World!\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.v.items.len == 2);
    try expect(eql(u8, value.Set.v.items[0].String.v, "Hello"));
    try expect(eql(u8, value.Set.v.items[1].String.v, "World!"));
}

test "set of mixed values" {
    var decoder = Decoder.init("~2\r\n+Hello\r\n:100\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.v.items.len == 2);
    try expect(eql(u8, value.Set.v.items[0].String.v, "Hello"));
    try expect(value.Set.v.items[1].Number.v == 100);
}

test "set with nested arrays" {
    var decoder = Decoder.init("~2\r\n+Hello\r\n*3\r\n+World!\r\n:100\r\n*1\r\n#t\r\n", test_allocator);
    const value = try decoder.decode();
    defer _ = value.deinit();
    try expect(value.Set.v.items.len == 2);
    try expect(eql(u8, value.Set.v.items[0].String.v, "Hello"));
    try expect(value.Set.v.items[1].Array.v.items.len == 3);
    try expect(eql(u8, value.Set.v.items[1].Array.v.items[0].String.v, "World!"));
    try expect(value.Set.v.items[1].Array.v.items[1].Number.v == 100);
    try expect(value.Set.v.items[1].Array.v.items[2].Array.v.items.len == 1);
    try expect(value.Set.v.items[1].Array.v.items[2].Array.v.items[0].Boolean.v == true);
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
    try expect(value.Push.v.items.len == 2);
    try expect(eql(u8, value.Push.v.items[0].String.v, "Hello"));
    try expect(eql(u8, value.Push.v.items[1].String.v, "World!"));
}

test "push first position is not a string" {
    var decoder = Decoder.init(">2\r\n:100\r\n:100\r\n", test_allocator);
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.PushExpectedString);
    };
}
