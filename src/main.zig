const std = @import("std");
const expect = std.testing.expect;
const Decoder = @import("decoder.zig").Decoder;
const eql = std.mem.eql;

pub fn main() !void {
    var decoder = Decoder{ .msg = "+OK\r\n" };
    const value = try decoder.decode();
    try expect(eql(u8, value.string, "OK"));
}

test {}
