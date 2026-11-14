const std = @import("std");
const time_mod = @import("time.zig");
const duration_mod = @import("duration.zig");
const context = @import("../context.zig");
const Mutex = @import("../sync/mutex.zig").Mutex;

pub const Time = time_mod.Time;
pub const Duration = duration_mod.Duration;

/// Limit defines the maximum frequency of some events.
/// Represented as number of events per second.
/// A zero Limit allows no events.
pub const Limit = f64;

/// Inf is the infinite rate limit; it allows all events (even if burst is zero).
pub const inf: Limit = std.math.inf(f64);

/// Every converts a minimum time interval between events to a Limit.
pub fn every(d: Duration) Limit {
    const ns = d.nanoseconds();
    if (ns <= 0) return inf;
    return 1e9 / @as(f64, @floatFromInt(ns));
}

pub const Reservation = struct {
    ok: bool,
    lim: *Limiter,
    tokens: u32,
    time_to_act: Time,
    limit: Limit,

    pub fn delayFrom(self: Reservation, now: Time) Duration {
        if (!self.ok) return @enumFromInt(0);
        const diff = self.time_to_act.sub(now);
        if (diff.nanoseconds() <= 0) return @enumFromInt(0);
        return diff;
    }

    pub fn delay(self: Reservation, io: std.Io) Duration {
        return self.delayFrom(Time.now(io));
    }

    pub fn cancel(self: *Reservation, io: std.Io) void {
        self.cancelAt(Time.now(io));
    }

    pub fn cancelAt(self: *Reservation, now: Time) void {
        if (!self.ok) return;
        self.lim.mutex.lock();
        defer self.lim.mutex.unlock();
        self.lim.advance(now);
        self.lim.tokens = @min(
            @as(f64, @floatFromInt(self.lim.burst_val)),
            self.lim.tokens + @as(f64, @floatFromInt(self.tokens)),
        );
        self.ok = false;
    }
};

pub const RateError = error{
    ExceedsBurst,
} || context.Error || std.Io.Cancelable || std.Io.UnexpectedError;

/// Limiter controls how frequently events are allowed to happen.
/// It implements a "token bucket" of size b, initially full and refilled
/// at rate r tokens per second.
pub const Limiter = struct {
    limit_val: Limit,
    burst_val: u32,
    tokens: f64,
    last: Time,
    mutex: Mutex = .{},

    pub fn init(r: Limit, b: u32) Limiter {
        return .{
            .limit_val = r,
            .burst_val = b,
            .tokens = @as(f64, @floatFromInt(b)),
            .last = Time.unix(0, 0),
        };
    }

    pub fn limit(self: *Limiter) Limit {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.limit_val;
    }

    pub fn setLimit(self: *Limiter, new_limit: Limit) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.limit_val = new_limit;
    }

    pub fn setLimitAt(self: *Limiter, now: Time, new_limit: Limit) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.advance(now);
        self.limit_val = new_limit;
    }

    pub fn burst(self: *Limiter) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.burst_val;
    }

    pub fn setBurst(self: *Limiter, new_burst: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.burst_val = new_burst;
        if (self.tokens > @as(f64, @floatFromInt(new_burst))) {
            self.tokens = @as(f64, @floatFromInt(new_burst));
        }
    }

    pub fn setBurstAt(self: *Limiter, now: Time, new_burst: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.advance(now);
        self.burst_val = new_burst;
        if (self.tokens > @as(f64, @floatFromInt(new_burst))) {
            self.tokens = @as(f64, @floatFromInt(new_burst));
        }
    }

    fn advance(self: *Limiter, now: Time) void {
        if (self.last.wall_sec == 0 and self.last.nsec == 0) {
            self.last = now;
            return;
        }
        const diff = now.sub(self.last);
        const elapsed_ns = diff.nanoseconds();
        if (elapsed_ns <= 0) return;

        self.last = now;
        if (std.math.isInf(self.limit_val)) {
            self.tokens = @as(f64, @floatFromInt(self.burst_val));
            return;
        }

        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        const delta = elapsed_sec * self.limit_val;
        self.tokens = @min(@as(f64, @floatFromInt(self.burst_val)), self.tokens + delta);
    }

    /// Allow is shorthand for AllowN(Time.now(io), 1).
    pub fn allow(self: *Limiter, io: std.Io) bool {
        return self.allowN(Time.now(io), 1);
    }

    /// AllowN reports whether n events may happen at time now.
    pub fn allowN(self: *Limiter, now: Time, n: u32) bool {
        return self.reserveNInternal(now, n, @enumFromInt(0)).ok;
    }

    /// Reserve is shorthand for ReserveN(Time.now(io), 1).
    pub fn reserve(self: *Limiter, io: std.Io) Reservation {
        return self.reserveN(Time.now(io), 1);
    }

    /// ReserveN returns a Reservation that indicates how long the caller must wait before n events happen.
    pub fn reserveN(self: *Limiter, now: Time, n: u32) Reservation {
        return self.reserveNInternal(now, n, null);
    }

    fn reserveNInternal(self: *Limiter, now: Time, n: u32, max_future_reserve: ?Duration) Reservation {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (n > self.burst_val and !std.math.isInf(self.limit_val)) {
            return .{
                .ok = false,
                .lim = self,
                .tokens = n,
                .time_to_act = now,
                .limit = self.limit_val,
            };
        }

        self.advance(now);

        const n_f = @as(f64, @floatFromInt(n));
        if (self.tokens >= n_f) {
            self.tokens -= n_f;
            return .{
                .ok = true,
                .lim = self,
                .tokens = n,
                .time_to_act = now,
                .limit = self.limit_val,
            };
        }

        if (std.math.isInf(self.limit_val) or self.limit_val <= 0) {
            return .{
                .ok = false,
                .lim = self,
                .tokens = n,
                .time_to_act = now,
                .limit = self.limit_val,
            };
        }

        // Calculate time needed for missing tokens
        const needed = n_f - self.tokens;
        const delay_sec = needed / self.limit_val;
        const delay_ns: i64 = @intFromFloat(delay_sec * 1e9);
        const delay_d: Duration = @enumFromInt(delay_ns);

        if (max_future_reserve) |max_d| {
            if (delay_d.nanoseconds() > max_d.nanoseconds()) {
                return .{
                    .ok = false,
                    .lim = self,
                    .tokens = n,
                    .time_to_act = now,
                    .limit = self.limit_val,
                };
            }
        }

        const time_to_act = now.add(delay_d);
        self.tokens -= n_f;

        return .{
            .ok = true,
            .lim = self,
            .tokens = n,
            .time_to_act = time_to_act,
            .limit = self.limit_val,
        };
    }

    /// Wait is shorthand for WaitN(ctx, io, 1).
    pub fn wait(self: *Limiter, ctx: context.Context, io: std.Io) RateError!void {
        return self.waitN(ctx, io, 1);
    }

    /// WaitN blocks until n events are allowed, or until ctx is canceled.
    pub fn waitN(self: *Limiter, ctx: context.Context, io: std.Io, n: u32) RateError!void {
        if (ctx.err()) |e| return e;

        const now = Time.now(io);
        var res = self.reserveN(now, n);
        if (!res.ok) return RateError.ExceedsBurst;

        const d = res.delayFrom(now);
        if (d.nanoseconds() <= 0) return;

        // Check deadline before sleeping
        if (ctx.deadline()) |dl| {
            if (now.add(d).sub(dl).nanoseconds() > 0) {
                res.cancelAt(now);
                return context.Error.DeadlineExceeded;
            }
        }

        try io.sleep(std.Io.Duration.fromNanoseconds(d.nanoseconds()), .awake);
        if (ctx.err()) |e| return e;
    }
};

test "rate.Limiter basic allow and burst" {
    const testing = std.testing;

    // 10 events per second, burst 3
    var lim = Limiter.init(10, 3);
    const t0 = Time.unix(1000, 0);

    // Initial burst of 3 should succeed immediately
    try testing.expect(lim.allowN(t0, 1));
    try testing.expect(lim.allowN(t0, 1));
    try testing.expect(lim.allowN(t0, 1));

    // 4th request at the same instant exceeds burst capacity
    try testing.expect(!lim.allowN(t0, 1));

    // After 100ms (0.1s), 1 token should have regenerated (10/s * 0.1s = 1)
    const t1 = t0.add(try duration_mod.parseDuration("100ms"));
    try testing.expect(lim.allowN(t1, 1));
    try testing.expect(!lim.allowN(t1, 1));

    // After 1 second, bucket should refill up to burst limit of 3
    const t2 = t1.add(try duration_mod.parseDuration("1s"));
    try testing.expect(lim.allowN(t2, 3));
    try testing.expect(!lim.allowN(t2, 1));
}

test "rate.Limiter reservation and cancellation" {
    const testing = std.testing;

    var lim = Limiter.init(5, 2); // 5 tokens/sec, burst 2
    const t0 = Time.unix(2000, 0);

    var r1 = lim.reserveN(t0, 2);
    try testing.expect(r1.ok);
    try testing.expectEqual(@as(i64, 0), r1.delayFrom(t0).nanoseconds());

    // Next token requires 1/5 second (200ms) wait
    var r2 = lim.reserveN(t0, 1);
    try testing.expect(r2.ok);
    try testing.expect(r2.delayFrom(t0).nanoseconds() > 0);

    // Cancel r2, refunding the token
    r2.cancelAt(t0);

    // After cancel, reserve should be granted again
    const r3 = lim.reserveN(t0, 1);
    try testing.expect(r3.ok);
}

test "rate.Limiter wait with context and std.Io" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var lim = Limiter.init(50, 2); // 50 tokens/sec
    const bg = context.background();

    // Burst tokens should not wait
    try lim.wait(bg, io);
    try lim.wait(bg, io);

    // Next token should wait ~20ms and succeed
    try lim.wait(bg, io);

    // Test context deadline exceeded
    const expired = Time.unix(0, 0);
    const dl_node = try context.withDeadline(testing.allocator, bg, expired);
    defer testing.allocator.destroy(dl_node);

    // Consume burst
    _ = lim.reserve(io);
    _ = lim.reserve(io);

    // Should fail with deadline exceeded because deadline is already in the past
    const err = lim.wait(dl_node.context(), io);
    try testing.expectEqual(context.Error.DeadlineExceeded, err);
}
