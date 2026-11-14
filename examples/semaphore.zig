//! Example demonstrating stdgo.sync.semaphore (Weighted Semaphore).
//!
//! Run with: zig build run-semaphore

const std = @import("std");
const stdgo = @import("stdgo");
const sync = stdgo.sync;
const context = stdgo.context;

pub fn main(init: std.process.Init) !void {
    std.debug.print("=== stdgo sync.semaphore (Weighted) Demo ===\n\n", .{});

    // 1. Initialize a weighted semaphore with capacity 4 driven by init.io
    var sem = sync.Semaphore.init(4, init.io);

    std.debug.print("1. Semaphore created with total capacity: 4\n\n", .{});

    // 2. TryAcquire demonstration
    std.debug.print("2. TryAcquire tests:\n", .{});
    const ok1 = sem.tryAcquire(3);
    std.debug.print("   -> tryAcquire(3): {s} (cur = 3/4)\n", .{if (ok1) "SUCCESS" else "FAILED"});

    const ok2 = sem.tryAcquire(2);
    std.debug.print("   -> tryAcquire(2): {s} (insufficient capacity, 1 remaining)\n", .{if (ok2) "SUCCESS" else "FAILED"});

    const ok3 = sem.tryAcquire(1);
    std.debug.print("   -> tryAcquire(1): {s} (cur = 4/4)\n", .{if (ok3) "SUCCESS" else "FAILED"});

    sem.release(4);
    std.debug.print("   -> Released 4 weight (cur = 0/4)\n\n", .{});

    // 3. Concurrent Task Rate Limiting
    std.debug.print("3. Concurrently executing 6 tasks with max weight limit of 4:\n", .{});

    const Task = struct {
        id: usize,
        weight: i64,
        sem_ptr: *sync.Semaphore,

        fn run(self: @This()) void {
            const bg_ctx = context.background();
            self.sem_ptr.acquire(bg_ctx, self.weight) catch return;
            defer self.sem_ptr.release(self.weight);

            std.debug.print("   [Task {d}] Acquired weight {d}. Processing...\n", .{ self.id, self.weight });
            var dummy: u64 = 0;
            for (0..1_000_000) |j| {
                dummy +%= j;
            }
            std.mem.doNotOptimizeAway(dummy);
            std.debug.print("   [Task {d}] Finished and released weight {d}.\n", .{ self.id, self.weight });
        }
    };

    var threads: [6]std.Thread = undefined;
    const weights = [_]i64{ 2, 2, 3, 1, 2, 2 };

    for (0..6) |i| {
        threads[i] = try std.Thread.spawn(.{}, Task.run, .{Task{
            .id = i + 1,
            .weight = weights[i],
            .sem_ptr = &sem,
        }});
    }

    for (0..6) |i| {
        threads[i].join();
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
