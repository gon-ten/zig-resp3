const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const expect = std.testing.expect;

const Value = union(enum) { string: []const u8, integer: i64, float: f64, boolean: bool };

pub const Decoder = struct {
    msg: []const u8 = undefined,

    read_position: usize = 0,

    fn peekChar(self: *Decoder) ?u8 {
        return self.msg[self.read_position];
    }

    pub fn decode(self: *Decoder) !Value {
        return try self.readNext();
    }

    fn readNext(self: *Decoder) !Value {
        if (self.readByte()) |byte| {
            switch (byte) {
                '+' => return try self.decodeString(),
                ':' => return try self.decodeInteger(),
                ',' => return try self.decodeFloat(),
                '#' => return try self.decodeBoolean(),
                else => unreachable,
            }
        }
        return error.Unexpected;
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

    fn decodeString(self: *Decoder) !Value {
        const line = try self.readUntilNewLine();
        return Value{ .string = line };
    }

    fn decodeInteger(self: *Decoder) !Value {
        const line = try self.readUntilNewLine();
        const integer = try std.fmt.parseInt(i64, line, 10);
        return Value{ .integer = integer };
    }

    fn decodeFloat(self: *Decoder) !Value {
        const line = try self.readUntilNewLine();
        if (eql(u8, line, "inf")) {
            return Value{ .float = std.math.inf(f64) };
        } else if (eql(u8, line, "-inf")) {
            return Value{ .float = -std.math.inf(f64) };
        } else if (eql(u8, line, "nan")) {
            return Value{ .float = std.math.nan(f64) };
        }
        const float = try std.fmt.parseFloat(f64, line);
        return Value{ .float = float };
    }

    fn decodeBoolean(self: *Decoder) !Value {
        const line = try self.readUntilNewLine();
        if (line.len > 1) {
            return error.IllegalValue;
        }

        if (eql(u8, line, "f")) {
            return Value{ .boolean = false };
        } else if (eql(u8, line, "t")) {
            return Value{ .boolean = true };
        }

        return error.IllegalValue;
    }

    fn readUntilNewLine(self: *Decoder) ![]const u8 {
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
            return error.EndOfBuffer;
        }

        try self.eatNewLine();

        return msg[current_position..new_line_index];
    }

    fn eatNewLine(self: *Decoder) !void {
        try self.assertIsEnded();

        const current_index = self.read_position;

        const next_two_bytes = self.msg[current_index .. current_index + 2];

        if (!eql(u8, next_two_bytes, "\r\n")) {
            return error.ExpectedCRLF;
        }

        self.read_position += 2;
    }

    fn assertIsEnded(self: *Decoder) error{EndOfBuffer}!void {
        if (self.read_position >= self.msg.len) {
            return error.EndOfBuffer;
        }
    }
};
pub fn main() !void {
    const decoder = Decoder{};
    _ = decoder;
}

test "decode simple string" {
    var decoder = Decoder{ .msg = "+OK\r\n" };
    const value = try decoder.decode();
    try expect(eql(u8, value.string, "OK"));
}

test "decode integer" {
    var decoder = Decoder{ .msg = ":100\r\n" };
    var value = try decoder.decode();
    try expect(value.integer == 100);
    decoder = Decoder{ .msg = ":-100\r\n" };
    value = try decoder.decode();
    try expect(value.integer == -100);
}

test "decode float" {
    var decoder = Decoder{ .msg = ",2.2\r\n" };
    var value = try decoder.decode();
    try expect(value.float == 2.2);
    decoder = Decoder{ .msg = ",-2.2\r\n" };
    value = try decoder.decode();
    try expect(value.float == -2.2);
    decoder = Decoder{ .msg = ",inf\r\n" };
    value = try decoder.decode();
    try expect(std.math.isInf(value.float));
    decoder = Decoder{ .msg = ",-inf\r\n" };
    value = try decoder.decode();
    try expect(std.math.isNegativeInf(value.float));
    decoder = Decoder{ .msg = ",nan\r\n" };
    value = try decoder.decode();
    try expect(std.math.isNan(value.float));
}

test "decode boolean" {
    var decoder = Decoder{ .msg = "#t\r\n" };
    var value = try decoder.decode();
    try expect(value.boolean == true);
    decoder = Decoder{ .msg = "#f\r\n" };
    value = try decoder.decode();
    try expect(value.boolean == false);
}
