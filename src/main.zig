const std = @import("std");
const expect = std.testing.expect;
const Decoder = @import("decoder.zig").Decoder;
const eql = std.mem.eql;
const page_allocator = std.heap.page_allocator;

pub fn main() !void {
    var decoder = Decoder.init("+OK\r\n", page_allocator);
    defer decoder.deinit();
    const value = try decoder.decode();
    defer value.deinit();
    try expect(eql(u8, value.String, "OK"));
}

test {}
