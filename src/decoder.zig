const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const expect = std.testing.expect;

const Error = struct { code: []const u8, message: []const u8 };

const Value = union(enum) { String: []const u8, BlobString: []const u8, Number: i64, Float: f64, Boolean: bool, Error: Error, BlobError: Error, Null: bool };

pub const DecoderError = error{ ExpectedLength, EndOfMessage, InvalidCharacter, ExpectedCRLF, ExpectedEOL, UnhandledMessageType, UnexpectedCharacterAfterNull, InvalidBooleanValue, InternalError };

pub const Decoder = struct {
    msg: []const u8 = undefined,

    read_position: usize = 0,

    pub fn decode(self: *Decoder) DecoderError!Value {
        return try self.readNext();
    }

    fn peekChar(self: *Decoder) DecoderError!u8 {
        if (self.read_position >= self.msg.len) {
            return DecoderError.EndOfMessage;
        }
        return self.msg[self.read_position];
    }

    fn readNext(self: *Decoder) DecoderError!Value {
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

    fn readByte(self: *Decoder) ?u8 {
        const msg = self.msg;
        if (self.read_position >= msg.len) {
            return null;
        }
        const char = msg[self.read_position];
        self.read_position += 1;
        return char;
    }

    fn decodeString(self: *Decoder) DecoderError!Value {
        const line = try self.readUntilNewLine();
        return Value{ .String = line };
    }

    fn decodeBlobString(self: *Decoder) DecoderError!Value {
        const length = try self.readLengthLine();
        const bytes = try self.readBytes(length);
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.ExpectedEOL;
        }
        return Value{ .BlobString = bytes };
    }

    fn decodeInteger(self: *Decoder) DecoderError!Value {
        const line = try self.readUntilNewLine();
        const integer = std.fmt.parseInt(i64, line, 10) catch |err| switch (err) {
            error.Overflow => return DecoderError.InternalError,
            error.InvalidCharacter => return DecoderError.InvalidCharacter,
        };
        return Value{ .Number = integer };
    }

    fn decodeFloat(self: *Decoder) DecoderError!Value {
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

    fn decodeBoolean(self: *Decoder) DecoderError!Value {
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

    fn decodeError(self: *Decoder) DecoderError!Value {
        const line = try self.readUntilNewLine();
        const error_value = try self.parseError(line);
        return Value{ .Error = error_value };
    }

    fn decodeBlobError(self: *Decoder) DecoderError!Value {
        const length = try self.readLengthLine();
        const bytes = try self.readBytes(length);
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.ExpectedEOL;
        }
        return Value{ .BlobError = try self.parseError(bytes) };
    }

    fn decodeNull(self: *Decoder) DecoderError!Value {
        const nextChar = try self.peekChar();
        if (nextChar != '\r') {
            return DecoderError.UnexpectedCharacterAfterNull;
        }
        try self.eatNewLine();
        return Value{ .Null = true };
    }

    fn decodeArray(self: *Decoder) DecoderError!Value {
        _ = self;
        return Value{ .Boolean = true };
    }

    fn readBytes(self: *Decoder, length: usize) DecoderError![]const u8 {
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

    fn readUntilNewLine(self: *Decoder) DecoderError![]const u8 {
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

    fn eatNewLine(self: *Decoder) DecoderError!void {
        try self.assertIsEnded();
        const current_index = self.read_position;
        const next_two_bytes = self.msg[current_index .. current_index + 2];
        if (!eql(u8, next_two_bytes, "\r\n")) {
            return DecoderError.ExpectedCRLF;
        }
        self.read_position += 2;
    }

    fn assertIsEnded(self: *Decoder) DecoderError!void {
        if (self.read_position >= self.msg.len) {
            return DecoderError.EndOfMessage;
        }
    }

    fn readLengthLine(self: *Decoder) DecoderError!usize {
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

    fn parseError(_: *Decoder, raw: []const u8) DecoderError!Error {
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

test "decode simple string" {
    var decoder = Decoder{ .msg = "+OK\r\n" };
    const value = try decoder.decode();
    try expect(eql(u8, value.String, "OK"));
}

test "decode blob string" {
    var decoder = Decoder{ .msg = "$2\r\nOK\r\n" };
    var value = try decoder.decode();
    try expect(eql(u8, value.BlobString, "OK"));
    decoder = Decoder{ .msg = "$0\r\n\r\n" };
    value = try decoder.decode();
    try expect(eql(u8, value.BlobString, ""));
    decoder = Decoder{ .msg = "$adff\r\nOK\r\n" };
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
    decoder = Decoder{ .msg = "$2\r\nO\r\n" };
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedEOL);
    };
}

test "decode integer" {
    var decoder = Decoder{ .msg = ":100\r\n" };
    var value = try decoder.decode();
    try expect(value.Number == 100);
    decoder = Decoder{ .msg = ":-100\r\n" };
    value = try decoder.decode();
    try expect(value.Number == -100);
}

test "decode float" {
    var decoder = Decoder{ .msg = ",2.2\r\n" };
    var value = try decoder.decode();
    try expect(value.Float == 2.2);
    decoder = Decoder{ .msg = ",-2.2\r\n" };
    value = try decoder.decode();
    try expect(value.Float == -2.2);
    decoder = Decoder{ .msg = ",inf\r\n" };
    value = try decoder.decode();
    try expect(std.math.isInf(value.Float));
    decoder = Decoder{ .msg = ",-inf\r\n" };
    value = try decoder.decode();
    try expect(std.math.isNegativeInf(value.Float));
    decoder = Decoder{ .msg = ",nan\r\n" };
    value = try decoder.decode();
    try expect(std.math.isNan(value.Float));
}

test "decode boolean" {
    var decoder = Decoder{ .msg = "#t\r\n" };
    var value = try decoder.decode();
    try expect(value.Boolean == true);
    decoder = Decoder{ .msg = "#f\r\n" };
    value = try decoder.decode();
    try expect(value.Boolean == false);
}

test "decode error" {
    var decoder = Decoder{ .msg = "-ERR Something went wrong\r\n" };
    var value = try decoder.decode();
    try expect(eql(u8, value.Error.code, "ERR"));
    try expect(eql(u8, value.Error.message, "Something went wrong"));
    decoder = Decoder{ .msg = "-ERR\r\n" };
    value = try decoder.decode();
    try expect(eql(u8, value.Error.code, "ERR"));
    try expect(eql(u8, value.Error.message, ""));
}

test "decode blob error" {
    var decoder = Decoder{ .msg = "!24\r\nERR Something went wrong\r\n" };
    var value = try decoder.decode();
    try expect(eql(u8, value.BlobError.code, "ERR"));
    try expect(eql(u8, value.BlobError.message, "Something went wrong"));
    decoder = Decoder{ .msg = "!3\r\nERR\r\n" };
    value = try decoder.decode();
    try expect(eql(u8, value.BlobError.code, "ERR"));
    try expect(eql(u8, value.BlobError.message, ""));
    decoder = Decoder{ .msg = "!\r\nERR\r\n" };
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.ExpectedLength);
    };
}

test "decode null" {
    var decoder = Decoder{ .msg = "_\r\n" };
    const value = try decoder.decode();
    try expect(value.Null);
}

test "unhandled message type" {
    var decoder = Decoder{ .msg = "^OK\r\n" };
    _ = decoder.decode() catch |err| {
        try expect(err == DecoderError.UnhandledMessageType);
    };
}
