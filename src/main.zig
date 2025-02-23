const std = @import("std");
const expect = std.testing.expect;
const Decoder = @import("decoder.zig").Decoder;
const eql = std.mem.eql;
const page_allocator = std.heap.page_allocator;
const print = std.debug.print;

pub fn main() !void {
    var decoder = Decoder.init("%3\r\n+key1\r\n%1\r\n+key1.1\r\n+value1.1\r\n+key\r\n*1\r\n=5\r\nmkd:h\r\n+sub\r\n*1\r\n:100\r\n", page_allocator);
    defer decoder.deinit();
    const value = try decoder.decode();
    defer value.deinit();
    print("{any}\n", .{value});
}

test {}
