const std = @import("std");
const backend = @import("backend.zig");

pub const Once = struct {
    // 0 = uninitialized, 1 = initializing, 2 = initialized
    state: backend.Value(u32) = .init(0),

    pub fn init() Once {
        return .{};
    }

    /// Do calls the function f if and only if Do is being called for the
    /// first time for this instance of Once.
    pub fn do(self: *Once, comptime f: anytype, args: anytype) void {
        doWithState(&self.state, yieldThread, f, args);
    }
};

fn yieldThread() void {
    backend.Thread.yield() catch {};
}

/// Uses the caller's zero-initialized atomic and scheduler for the same Once protocol.
pub fn doWithState(state: anytype, comptime yield: fn () void, comptime f: anytype, args: anytype) void {
    if (state.load(.acquire) == 2) return;
    if (state.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
        while (state.load(.acquire) != 2) yield();
        return;
    }
    @call(.auto, f, args);
    state.store(2, .release);
}

test "sync.Once executed exactly once across threads" {
    const testing = std.testing;

    var once = Once.init();
    var executed_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

    const Helper = struct {
        fn initFunc(counter: *std.atomic.Value(i32)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }

        fn worker(o: *Once, counter: *std.atomic.Value(i32)) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                o.do(initFunc, .{counter});
            }
        }
    };

    const num_threads = 8;
    var threads: [num_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Helper.worker, .{ &once, &executed_count });
    }

    for (threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(i32, 1), executed_count.load(.monotonic));
}
