//! Package sync/semaphore provides a weighted semaphore implementation,
//! equivalent to Go's golang.org/x/sync/semaphore.
//!
//! Designed for cooperative concurrency control without POSIX C system calls,
//! fully integrating with stdgo.context.Context for deadlines and cancellation.

const std = @import("std");
const backend = @import("backend.zig");
const Mutex = @import("mutex.zig").Mutex;
const context = @import("../context.zig");
const Context = context.Context;

pub const Error = error{
    Canceled,
    DeadlineExceeded,
    WeightExceedsCapacity,
};

/// Waiter node in the FIFO queue to guarantee fair, starvation-free scheduling.
const Waiter = struct {
    n: i64,
    ready: backend.Value(bool),
    next: ?*Waiter = null,
    prev: ?*Waiter = null,
};

/// Weighted provides a concurrent, weighted semaphore implementation.
pub const Weighted = struct {
    size: i64,
    cur: i64 = 0,
    io: ?std.Io = null,
    mu: Mutex = .{},
    head: ?*Waiter = null,
    tail: ?*Waiter = null,

    /// Initializes a Weighted semaphore with the given maximum weight capacity.
    /// An optional std.Io can be provided to drive cooperative sleeping without OS calls.
    pub fn init(n: i64, io: ?std.Io) Weighted {
        std.debug.assert(n > 0);
        return .{
            .size = n,
            .cur = 0,
            .io = io,
            .mu = .{},
            .head = null,
            .tail = null,
        };
    }

    /// Tries to acquire the semaphore with weight n without blocking.
    /// On success, returns true. On failure, returns false and leaves the semaphore unchanged.
    pub fn tryAcquire(self: *Weighted, n: i64) bool {
        std.debug.assert(n > 0);
        self.mu.lock();
        defer self.mu.unlock();

        if (self.size - self.cur >= n and self.head == null) {
            self.cur += n;
            return true;
        }
        return false;
    }

    /// Acquires the semaphore with weight n, blocking until resources are available
    /// or ctx is done (canceled or deadline exceeded).
    /// On failure, no resources are retained.
    pub fn acquire(self: *Weighted, ctx: Context, n: i64) Error!void {
        std.debug.assert(n > 0);
        if (n > self.size) {
            return Error.WeightExceedsCapacity;
        }

        self.mu.lock();

        // 1. Fast path: enough capacity and nobody ahead in FIFO queue
        if (self.size - self.cur >= n and self.head == null) {
            self.cur += n;
            self.mu.unlock();
            return;
        }

        // Check if context is already expired
        if (ctx.done()) {
            self.mu.unlock();
            return mapContextError(ctx);
        }

        // 2. Slow path: enqueue waiter to ensure FIFO fairness and prevent starvation
        var w = Waiter{
            .n = n,
            .ready = .init(false),
            .next = null,
            .prev = self.tail,
        };

        if (self.tail) |t| {
            t.next = &w;
            self.tail = &w;
        } else {
            self.head = &w;
            self.tail = &w;
        }

        self.mu.unlock();

        // 3. Wait loop: yield / sleep cooperatively while monitoring ready and ctx
        while (true) {
            if (w.ready.load(.acquire)) {
                return;
            }

            if (ctx.done()) {
                self.mu.lock();
                // Check if ready became true just before taking the lock
                if (w.ready.load(.acquire)) {
                    self.mu.unlock();
                    return;
                }

                // Remove from waiter queue
                self.removeWaiter(&w);
                // Wake up next eligible waiters if any
                self.notifyWaiters();
                self.mu.unlock();
                return mapContextError(ctx);
            }

            if (self.io) |io_val| {
                io_val.sleep(std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_us), .awake) catch {};
            } else {
                backend.Thread.yield() catch {};
            }
        }
    }

    /// Releases the semaphore with a weight of n.
    pub fn release(self: *Weighted, n: i64) void {
        std.debug.assert(n > 0);
        self.mu.lock();
        defer self.mu.unlock();

        self.cur -= n;
        std.debug.assert(self.cur >= 0);

        self.notifyWaiters();
    }

    /// Wakes up as many FIFO waiters as capacity allows.
    fn notifyWaiters(self: *Weighted) void {
        while (self.head) |w| {
            if (self.size - self.cur < w.n) {
                // Front waiter cannot be satisfied; don't bypass (FIFO)
                break;
            }
            self.cur += w.n;
            self.removeWaiter(w);
            w.ready.store(true, .release);
        }
    }

    fn removeWaiter(self: *Weighted, w: *Waiter) void {
        if (w.prev) |p| {
            p.next = w.next;
        } else {
            self.head = w.next;
        }

        if (w.next) |next| {
            next.prev = w.prev;
        } else {
            self.tail = w.prev;
        }

        w.prev = null;
        w.next = null;
    }

    fn mapContextError(ctx: Context) Error {
        if (ctx.err()) |e| {
            return switch (e) {
                error.Canceled => Error.Canceled,
                error.DeadlineExceeded => Error.DeadlineExceeded,
            };
        }
        return Error.Canceled;
    }
};

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "Weighted: tryAcquire and release" {
    const testing = std.testing;

    var sem = Weighted.init(3, null);

    try testing.expect(sem.tryAcquire(2));
    try testing.expect(!sem.tryAcquire(2)); // Remaining is 1
    try testing.expect(sem.tryAcquire(1)); // Remaining is 0
    try testing.expect(!sem.tryAcquire(1));

    sem.release(2);
    try testing.expect(sem.tryAcquire(2));
    sem.release(3);
}

test "Weighted: acquire with background context" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sem = Weighted.init(2, io);
    const bg = context.background();

    try sem.acquire(bg, 1);
    try sem.acquire(bg, 1);
    try testing.expect(!sem.tryAcquire(1));

    sem.release(2);
}

test "Weighted: acquire context cancel" {
    const testing = std.testing;

    var sem = Weighted.init(1, null);
    const bg = context.background();
    try sem.acquire(bg, 1);

    var cancel_ctx = try context.withCancel(testing.allocator, bg);
    defer testing.allocator.destroy(cancel_ctx);

    // Cancel immediately
    cancel_ctx.cancel();

    const err = sem.acquire(cancel_ctx.context(), 1);
    try testing.expectEqual(Error.Canceled, err);

    sem.release(1);
}

test "Weighted: concurrent worker rate limiting" {
    const testing = std.testing;

    var sem = Weighted.init(2, null);
    var active_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
    var max_observed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    const Worker = struct {
        fn run(s: *Weighted, active: *std.atomic.Value(usize), max_obs: *std.atomic.Value(usize)) void {
            const bg = context.background();
            for (0..10) |_| {
                s.acquire(bg, 1) catch return;
                const cur = active.fetchAdd(1, .monotonic) + 1;

                var old_max = max_obs.load(.monotonic);
                while (cur > old_max) {
                    old_max = max_obs.cmpxchgWeak(old_max, cur, .monotonic, .monotonic) orelse break;
                }

                var dummy: u64 = 0;
                for (0..10_000) |j| {
                    dummy +%= j;
                }
                std.mem.doNotOptimizeAway(dummy);
                _ = active.fetchSub(1, .monotonic);
                s.release(1);
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, &active_count, &max_observed });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, &active_count, &max_observed });
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, &active_count, &max_observed });
    const t4 = try std.Thread.spawn(.{}, Worker.run, .{ &sem, &active_count, &max_observed });

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    try testing.expect(max_observed.load(.monotonic) <= 2);
}
