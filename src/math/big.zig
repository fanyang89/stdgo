const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Int = @import("big/int.zig").Int;

pub fn newInt(allocator: Allocator) !Int {
    return Int.init(allocator);
}

pub fn fromInt64(allocator: Allocator, x: i64) !Int {
    return Int.initSet(allocator, x);
}

pub fn fromUint64(allocator: Allocator, x: u64) !Int {
    return Int.initSet(allocator, x);
}

pub fn fromString(allocator: Allocator, s: []const u8, base: u8) !Int {
    var res = try Int.init(allocator);
    errdefer res.deinit();
    _ = try res.setString(s, base);
    return res;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("big/int.zig");
}
