const std = @import("std");
const Allocator = std.mem.Allocator;
const time = @import("../time.zig");
const Mutex = @import("../sync/mutex.zig").Mutex;

pub const Error = error{
    Canceled,
    DeadlineExceeded,
};

pub const WaitError = Error || std.Io.Cancelable;
pub const WaitTimeoutError = Error || std.Io.Cancelable || std.Io.Timeout.Error;

/// Intrusive subscription node for push-based cancellation propagation
/// (child contexts and `afterFunc` callbacks).
pub const Subscriber = struct {
    next: ?*Subscriber = null,
    prev: ?*Subscriber = null,
    subscribed: bool = false,
    on_cancel: *const fn (
        sub: *Subscriber,
        cancel_err: Error,
        cause_err: ?anyerror,
        io_opt: ?std.Io,
    ) void,
};

pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deadline: *const fn (ctx: *anyopaque) ?time.Time,
        done: *const fn (ctx: *anyopaque) bool,
        err: *const fn (ctx: *anyopaque) ?Error,
        cause: *const fn (ctx: *anyopaque) ?anyerror,
        value: *const fn (ctx: *anyopaque, key: []const u8) ?*const anyopaque,
        refresh: *const fn (ctx: *anyopaque, io: std.Io) void,
        wait: *const fn (ctx: *anyopaque, io: std.Io) WaitError!void,
        waitTimeout: *const fn (
            ctx: *anyopaque,
            io: std.Io,
            timeout: std.Io.Timeout,
        ) WaitTimeoutError!void,
        subscribe: *const fn (ctx: *anyopaque, sub: *Subscriber) bool,
        unsubscribe: *const fn (ctx: *anyopaque, sub: *Subscriber) void,
    };

    pub fn deadline(self: Context) ?time.Time {
        return self.vtable.deadline(self.ptr);
    }

    pub fn done(self: Context) bool {
        return self.vtable.done(self.ptr);
    }

    pub fn err(self: Context) ?Error {
        return self.vtable.err(self.ptr);
    }

    /// Returns the underlying cancellation cause if one was provided via
    /// `withCancelCause` / `withDeadlineCauseIo` / `withTimeoutCause`,
    /// otherwise returns `self.err()`.
    pub fn cause(self: Context) ?anyerror {
        return self.vtable.cause(self.ptr);
    }

    pub fn value(self: Context, key: []const u8) ?*const anyopaque {
        return self.vtable.value(self.ptr, key);
    }

    /// Type-safe wrapper around `value()` that casts the stored pointer to `*const T`.
    /// The caller must ensure `T` matches the type originally passed to `withValue()`.
    pub fn valueAs(self: Context, comptime T: type, key: []const u8) ?*const T {
        const ptr = self.value(key) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Refreshes time-based cancellation before reading the state.
    pub fn doneWithIo(self: Context, io: std.Io) bool {
        self.vtable.refresh(self.ptr, io);
        return self.done();
    }

    pub fn errWithIo(self: Context, io: std.Io) ?Error {
        self.vtable.refresh(self.ptr, io);
        return self.err();
    }

    /// Blocks until the context is canceled or its deadline expires, or until `io`
    /// itself is canceled. Returns `error.Canceled` or `error.DeadlineExceeded`.
    pub fn wait(self: Context, io: std.Io) WaitError!void {
        return self.vtable.wait(self.ptr, io);
    }

    /// Blocks until the context is done, `timeout` expires, or `io` is canceled.
    /// Returns `error.Timeout` if `timeout` elapsed before the context became done.
    pub fn waitTimeout(
        self: Context,
        io: std.Io,
        timeout: std.Io.Timeout,
    ) WaitTimeoutError!void {
        return self.vtable.waitTimeout(self.ptr, io, timeout);
    }

    /// Converts the context deadline into the timeout representation used by
    /// `std.Io` operations.
    pub fn ioTimeout(self: Context) std.Io.Timeout {
        if (self.deadline()) |deadline_time| {
            return .{ .deadline = .{
                .raw = .fromNanoseconds(@intCast(deadline_time.unixNano())),
                .clock = .real,
            } };
        }
        return .none;
    }

    pub fn isNoop(self: Context) bool {
        return self.vtable == &empty_vtable;
    }
};

/// Top-level helper matching Go's `context.Cause(ctx)`.
pub fn cause(ctx: Context) ?anyerror {
    return ctx.cause();
}

// --- Empty Root Context (Background / TODO) ---
const empty_vtable = Context.VTable{
    .deadline = struct {
        fn f(_: *anyopaque) ?time.Time {
            return null;
        }
    }.f,
    .done = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .err = struct {
        fn f(_: *anyopaque) ?Error {
            return null;
        }
    }.f,
    .cause = struct {
        fn f(_: *anyopaque) ?anyerror {
            return null;
        }
    }.f,
    .value = struct {
        fn f(_: *anyopaque, _: []const u8) ?*const anyopaque {
            return null;
        }
    }.f,
    .refresh = struct {
        fn f(_: *anyopaque, _: std.Io) void {}
    }.f,
    .wait = struct {
        fn f(_: *anyopaque, io: std.Io) WaitError!void {
            var never: std.Io.Event = .unset;
            try never.wait(io);
            unreachable;
        }
    }.f,
    .waitTimeout = struct {
        fn f(_: *anyopaque, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!void {
            var never: std.Io.Event = .unset;
            try never.waitTimeout(io, timeout);
            unreachable;
        }
    }.f,
    .subscribe = struct {
        fn f(_: *anyopaque, _: *Subscriber) bool {
            return true;
        }
    }.f,
    .unsubscribe = struct {
        fn f(_: *anyopaque, _: *Subscriber) void {}
    }.f,
};

var empty_dummy: u8 = 0;

pub fn background() Context {
    return .{
        .ptr = &empty_dummy,
        .vtable = &empty_vtable,
    };
}

pub fn todo() Context {
    return background();
}

// --- CancelContext ---
pub const CancelContext = struct {
    parent: Context,
    io: ?std.Io = null,
    has_notifier: bool = false,
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_err: ?Error = null,
    cause_err: ?anyerror = null,
    done_event: std.Io.Event = .unset,
    mutex: Mutex = .{},
    notify_mutex: Mutex = .{},
    notifying_thread: ?std.Thread.Id = null,
    subs_head: ?*Subscriber = null,
    parent_sub: Subscriber = .{ .on_cancel = onParentCancel },

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(ctx: *anyopaque) ?time.Time {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.parent.deadline();
            }
        }.f,
        .done = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.isDone();
            }
        }.f,
        .err = struct {
            fn f(ctx: *anyopaque) ?Error {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.getError();
            }
        }.f,
        .cause = struct {
            fn f(ctx: *anyopaque) ?anyerror {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.getCause();
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.parent.value(key);
            }
        }.f,
        .refresh = struct {
            fn f(ctx: *anyopaque, io: std.Io) void {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                self.parent.vtable.refresh(self.parent.ptr, io);
            }
        }.f,
        .wait = struct {
            fn f(ctx: *anyopaque, io: std.Io) WaitError!void {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.waitImpl(io, null);
            }
        }.f,
        .waitTimeout = struct {
            fn f(ctx: *anyopaque, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!void {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.waitTimeoutImpl(io, timeout, null);
            }
        }.f,
        .subscribe = struct {
            fn f(ctx: *anyopaque, sub: *Subscriber) bool {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                return self.subscribeImpl(sub);
            }
        }.f,
        .unsubscribe = struct {
            fn f(ctx: *anyopaque, sub: *Subscriber) void {
                const self: *CancelContext = @ptrCast(@alignCast(ctx));
                self.unsubscribeImpl(sub);
            }
        }.f,
    };

    pub fn context(self: *CancelContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn cancel(self: *CancelContext) void {
        self.cancelInternal(Error.Canceled, null, self.io);
    }

    pub fn cancelWithIo(self: *CancelContext, io: std.Io) void {
        self.cancelInternal(Error.Canceled, null, io);
    }

    pub fn cancelWithCause(self: *CancelContext, cause_err: anyerror) void {
        self.cancelInternal(Error.Canceled, cause_err, self.io);
    }

    pub fn cancelWithCauseIo(self: *CancelContext, cause_err: anyerror, io: std.Io) void {
        self.cancelInternal(Error.Canceled, cause_err, io);
    }

    pub fn deinit(self: *CancelContext, allocator: Allocator) void {
        self.cancel();
        self.parent.vtable.unsubscribe(self.parent.ptr, &self.parent_sub);
        allocator.destroy(self);
    }

    pub fn isDone(self: *CancelContext) bool {
        return self.canceled.load(.acquire) or self.parent.done();
    }

    pub fn getError(self: *CancelContext) ?Error {
        self.mutex.lock();
        const local_err = self.cancel_err;
        self.mutex.unlock();
        if (local_err) |e| return e;
        return self.parent.err();
    }

    pub fn getCause(self: *CancelContext) ?anyerror {
        self.mutex.lock();
        const local_cause = self.cause_err;
        const local_err = self.cancel_err;
        self.mutex.unlock();
        if (local_cause) |c| return c;
        if (local_err) |e| return e;
        return self.parent.cause();
    }

    fn onParentCancel(
        sub: *Subscriber,
        cancel_err: Error,
        cause_err: ?anyerror,
        io_opt: ?std.Io,
    ) void {
        const self: *CancelContext = @fieldParentPtr("parent_sub", sub);
        self.cancelInternal(cancel_err, cause_err, io_opt orelse self.io);
    }

    fn cancelInternal(
        self: *CancelContext,
        cancel_err: Error,
        cause_err: ?anyerror,
        io_opt: ?std.Io,
    ) void {
        if (self.canceled.load(.acquire)) return;

        const effective_io = io_opt orelse self.io;
        var detached_head: ?*Subscriber = null;
        var local_cause: ?anyerror = null;

        {
            self.notify_mutex.lock();
            defer self.notify_mutex.unlock();

            self.mutex.lock();
            if (self.canceled.load(.acquire)) {
                self.mutex.unlock();
                return;
            }
            self.cancel_err = cancel_err;
            local_cause = cause_err orelse cancel_err;
            self.cause_err = local_cause;
            self.canceled.store(true, .release);

            detached_head = self.subs_head;
            self.subs_head = null;
            var mark = detached_head;
            while (mark) |sub| {
                sub.subscribed = false;
                mark = sub.next;
            }
            if (detached_head != null) {
                self.notifying_thread = std.Thread.getCurrentId();
            }
            self.mutex.unlock();

            if (effective_io) |io| {
                self.done_event.set(io);
            } else {
                @atomicStore(std.Io.Event, &self.done_event, .is_set, .release);
            }

            if (detached_head != null) {
                defer {
                    self.mutex.lock();
                    self.notifying_thread = null;
                    self.mutex.unlock();
                }

                var cur = detached_head;
                while (cur) |sub| {
                    const next = sub.next;
                    sub.next = null;
                    sub.prev = null;
                    sub.on_cancel(sub, cancel_err, local_cause, effective_io);
                    cur = next;
                }
            }
        }

        // Unsubscribe from parent after releasing `self.notify_mutex` so lock
        // acquisition stays strictly top-down (parent -> child).
        self.parent.vtable.unsubscribe(self.parent.ptr, &self.parent_sub);
    }

    fn subscribeImpl(self: *CancelContext, sub: *Subscriber) bool {
        self.mutex.lock();
        if (self.canceled.load(.acquire)) {
            const c_err = self.cancel_err orelse Error.Canceled;
            const c_cause = self.cause_err;
            const io_opt = self.io;
            self.mutex.unlock();
            sub.on_cancel(sub, c_err, c_cause, io_opt);
            return false;
        }

        sub.prev = null;
        sub.next = self.subs_head;
        if (self.subs_head) |head| {
            head.prev = sub;
        }
        self.subs_head = sub;
        sub.subscribed = true;
        self.mutex.unlock();
        return true;
    }

    fn unsubscribeImpl(self: *CancelContext, sub: *Subscriber) void {
        self.mutex.lock();
        if (sub.subscribed) {
            if (sub.prev) |p| {
                p.next = sub.next;
            } else {
                self.subs_head = sub.next;
            }
            if (sub.next) |n| {
                n.prev = sub.prev;
            }
            sub.prev = null;
            sub.next = null;
            sub.subscribed = false;
            self.mutex.unlock();
            return;
        }
        const is_reentrant = if (self.notifying_thread) |tid|
            tid == std.Thread.getCurrentId()
        else
            false;
        self.mutex.unlock();

        if (is_reentrant) return;

        // Wait for any in-flight notification loop on another thread to finish
        // before the caller destroys `sub`.
        self.notify_mutex.lock();
        self.notify_mutex.unlock();
    }

    fn waitImpl(
        self: *CancelContext,
        io: std.Io,
        dl_ctx: ?*DeadlineContext,
    ) WaitError!void {
        if (dl_ctx) |d| {
            if (d.check(io)) return self.getError().?;
        } else {
            self.parent.vtable.refresh(self.parent.ptr, io);
            if (self.isDone()) return self.getError().?;
        }

        if (self.has_notifier) {
            try self.done_event.wait(io);
            return self.getError().?;
        }

        // Fallback for legacy contexts constructed without `io` where `cancel()`
        // cannot call `done_event.set(io)` to wake a futex.
        const poll_interval = std.Io.Duration.fromNanoseconds(1 * std.time.ns_per_ms);
        while (true) {
            if (dl_ctx) |d| {
                if (d.check(io)) return self.getError().?;
            } else {
                self.parent.vtable.refresh(self.parent.ptr, io);
                if (self.isDone()) return self.getError().?;
            }
            try io.sleep(poll_interval, .awake);
        }
    }

    fn waitTimeoutImpl(
        self: *CancelContext,
        io: std.Io,
        timeout: std.Io.Timeout,
        dl_ctx: ?*DeadlineContext,
    ) WaitTimeoutError!void {
        if (dl_ctx) |d| {
            if (d.check(io)) return self.getError().?;
        } else {
            self.parent.vtable.refresh(self.parent.ptr, io);
            if (self.isDone()) return self.getError().?;
        }

        if (self.has_notifier) {
            self.done_event.waitTimeout(io, timeout) catch |err| switch (err) {
                error.Timeout => {
                    if (dl_ctx) |d| {
                        if (d.check(io)) return self.getError().?;
                    } else if (self.isDone()) {
                        return self.getError().?;
                    }
                    return error.Timeout;
                },
                error.Canceled => |e| return e,
            };
            return self.getError().?;
        }

        const deadline_opt = timeout.toTimestamp(io);
        const poll_interval = std.Io.Duration.fromNanoseconds(1 * std.time.ns_per_ms);
        while (true) {
            if (dl_ctx) |d| {
                if (d.check(io)) return self.getError().?;
            } else {
                self.parent.vtable.refresh(self.parent.ptr, io);
                if (self.isDone()) return self.getError().?;
            }
            if (deadline_opt) |dl_ts| {
                if (dl_ts.untilNow(io).raw.nanoseconds >= 0) {
                    return error.Timeout;
                }
            }
            try io.sleep(poll_interval, .awake);
        }
    }
};

fn parentIo(parent: Context) ?std.Io {
    if (parent.vtable == &CancelContext.vtable) {
        const p: *CancelContext = @ptrCast(@alignCast(parent.ptr));
        return p.io;
    }
    if (parent.vtable == &DeadlineContext.vtable) {
        const p: *DeadlineContext = @ptrCast(@alignCast(parent.ptr));
        return p.cancel_ctx.io;
    }
    if (parent.vtable == &ValueContext.vtable) {
        const p: *ValueContext = @ptrCast(@alignCast(parent.ptr));
        return parentIo(p.parent);
    }
    return null;
}

fn createCancelContext(
    allocator: Allocator,
    io_opt: ?std.Io,
    parent: Context,
) Allocator.Error!*CancelContext {
    const effective_io = io_opt orelse parentIo(parent);
    const ctx = try allocator.create(CancelContext);
    ctx.* = .{
        .parent = parent,
        .io = effective_io,
        .has_notifier = (effective_io != null),
    };
    _ = parent.vtable.subscribe(parent.ptr, &ctx.parent_sub);
    return ctx;
}

pub fn withCancel(allocator: Allocator, parent: Context) Allocator.Error!*CancelContext {
    return createCancelContext(allocator, null, parent);
}

pub fn withCancelIo(
    allocator: Allocator,
    io: std.Io,
    parent: Context,
) Allocator.Error!*CancelContext {
    return createCancelContext(allocator, io, parent);
}

pub fn withCancelCause(allocator: Allocator, parent: Context) Allocator.Error!*CancelContext {
    return createCancelContext(allocator, null, parent);
}

pub fn withCancelCauseIo(
    allocator: Allocator,
    io: std.Io,
    parent: Context,
) Allocator.Error!*CancelContext {
    return createCancelContext(allocator, io, parent);
}

// --- ValueContext ---
pub const ValueContext = struct {
    parent: Context,
    key: []const u8,
    val_ptr: *const anyopaque,

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(ctx: *anyopaque) ?time.Time {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.deadline();
            }
        }.f,
        .done = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.done();
            }
        }.f,
        .err = struct {
            fn f(ctx: *anyopaque) ?Error {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.err();
            }
        }.f,
        .cause = struct {
            fn f(ctx: *anyopaque) ?anyerror {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.cause();
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                if (std.mem.eql(u8, self.key, key)) {
                    return self.val_ptr;
                }
                return self.parent.value(key);
            }
        }.f,
        .refresh = struct {
            fn f(ctx: *anyopaque, io: std.Io) void {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                self.parent.vtable.refresh(self.parent.ptr, io);
            }
        }.f,
        .wait = struct {
            fn f(ctx: *anyopaque, io: std.Io) WaitError!void {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.wait(io);
            }
        }.f,
        .waitTimeout = struct {
            fn f(ctx: *anyopaque, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!void {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.waitTimeout(io, timeout);
            }
        }.f,
        .subscribe = struct {
            fn f(ctx: *anyopaque, sub: *Subscriber) bool {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                return self.parent.vtable.subscribe(self.parent.ptr, sub);
            }
        }.f,
        .unsubscribe = struct {
            fn f(ctx: *anyopaque, sub: *Subscriber) void {
                const self: *ValueContext = @ptrCast(@alignCast(ctx));
                self.parent.vtable.unsubscribe(self.parent.ptr, sub);
            }
        }.f,
    };

    pub fn context(self: *ValueContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *ValueContext, allocator: Allocator) void {
        allocator.destroy(self);
    }
};

pub fn withValue(
    allocator: Allocator,
    parent: Context,
    key: []const u8,
    val_ptr: anytype,
) Allocator.Error!*ValueContext {
    const ctx = try allocator.create(ValueContext);
    ctx.* = .{
        .parent = parent,
        .key = key,
        .val_ptr = @ptrCast(val_ptr),
    };
    return ctx;
}

// --- WithoutCancelContext ---
pub const WithoutCancelContext = struct {
    parent: Context,

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(_: *anyopaque) ?time.Time {
                return null;
            }
        }.f,
        .done = struct {
            fn f(_: *anyopaque) bool {
                return false;
            }
        }.f,
        .err = struct {
            fn f(_: *anyopaque) ?Error {
                return null;
            }
        }.f,
        .cause = struct {
            fn f(_: *anyopaque) ?anyerror {
                return null;
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *WithoutCancelContext = @ptrCast(@alignCast(ctx));
                return self.parent.value(key);
            }
        }.f,
        .refresh = struct {
            fn f(_: *anyopaque, _: std.Io) void {}
        }.f,
        .wait = struct {
            fn f(_: *anyopaque, io: std.Io) WaitError!void {
                var never: std.Io.Event = .unset;
                try never.wait(io);
                unreachable;
            }
        }.f,
        .waitTimeout = struct {
            fn f(_: *anyopaque, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!void {
                var never: std.Io.Event = .unset;
                try never.waitTimeout(io, timeout);
                unreachable;
            }
        }.f,
        .subscribe = struct {
            fn f(_: *anyopaque, _: *Subscriber) bool {
                return true;
            }
        }.f,
        .unsubscribe = struct {
            fn f(_: *anyopaque, _: *Subscriber) void {}
        }.f,
    };

    pub fn context(self: *WithoutCancelContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *WithoutCancelContext, allocator: Allocator) void {
        allocator.destroy(self);
    }
};

/// Returns a derived context that keeps values from `parent` but is never canceled
/// when `parent` is canceled, matching Go's `context.WithoutCancel`.
pub fn withoutCancel(
    allocator: Allocator,
    parent: Context,
) Allocator.Error!*WithoutCancelContext {
    const ctx = try allocator.create(WithoutCancelContext);
    ctx.* = .{ .parent = parent };
    return ctx;
}

// --- DeadlineContext ---
pub const DeadlineContext = struct {
    cancel_ctx: CancelContext,
    deadline_val: time.Time,
    timeout_cause: ?anyerror = null,
    timer_thread: ?std.Thread = null,

    const vtable = Context.VTable{
        .deadline = struct {
            fn f(ctx: *anyopaque) ?time.Time {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.deadline_val;
            }
        }.f,
        .done = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.isDone();
            }
        }.f,
        .err = struct {
            fn f(ctx: *anyopaque) ?Error {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.getError();
            }
        }.f,
        .cause = struct {
            fn f(ctx: *anyopaque) ?anyerror {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.getCause();
            }
        }.f,
        .value = struct {
            fn f(ctx: *anyopaque, key: []const u8) ?*const anyopaque {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.parent.value(key);
            }
        }.f,
        .refresh = struct {
            fn f(ctx: *anyopaque, io: std.Io) void {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                self.cancel_ctx.parent.vtable.refresh(self.cancel_ctx.parent.ptr, io);
                _ = self.check(io);
            }
        }.f,
        .wait = struct {
            fn f(ctx: *anyopaque, io: std.Io) WaitError!void {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.waitImpl(io, self);
            }
        }.f,
        .waitTimeout = struct {
            fn f(ctx: *anyopaque, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!void {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.waitTimeoutImpl(io, timeout, self);
            }
        }.f,
        .subscribe = struct {
            fn f(ctx: *anyopaque, sub: *Subscriber) bool {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                return self.cancel_ctx.subscribeImpl(sub);
            }
        }.f,
        .unsubscribe = struct {
            fn f(ctx: *anyopaque, sub: *Subscriber) void {
                const self: *DeadlineContext = @ptrCast(@alignCast(ctx));
                self.cancel_ctx.unsubscribeImpl(sub);
            }
        }.f,
    };

    pub fn context(self: *DeadlineContext) Context {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn cancel(self: *DeadlineContext) void {
        self.cancel_ctx.cancel();
    }

    pub fn deinit(self: *DeadlineContext, allocator: Allocator) void {
        self.cancel_ctx.cancel();
        if (self.timer_thread) |t| {
            t.join();
            self.timer_thread = null;
        }
        self.cancel_ctx.parent.vtable.unsubscribe(
            self.cancel_ctx.parent.ptr,
            &self.cancel_ctx.parent_sub,
        );
        allocator.destroy(self);
    }

    /// Checks the current time against the deadline using caller-provided io.
    /// If expired, automatically cancels the context with DeadlineExceeded.
    pub fn check(self: *DeadlineContext, io: std.Io) bool {
        if (self.cancel_ctx.isDone()) return true;
        const now = time.Time.now(io);
        if (now.unixNano() >= self.deadline_val.unixNano()) {
            self.cancel_ctx.cancelInternal(
                Error.DeadlineExceeded,
                self.timeout_cause,
                io,
            );
            return true;
        }
        return false;
    }

    fn timerMain(self: *DeadlineContext, io: std.Io) void {
        const io_timeout: std.Io.Timeout = .{ .deadline = .{
            .raw = .fromNanoseconds(@intCast(self.deadline_val.unixNano())),
            .clock = .real,
        } };
        self.cancel_ctx.done_event.waitTimeout(io, io_timeout) catch |err| switch (err) {
            error.Timeout => {
                self.cancel_ctx.cancelInternal(
                    Error.DeadlineExceeded,
                    self.timeout_cause,
                    io,
                );
                return;
            },
            error.Canceled => return,
        };
    }
};

fn createDeadlineContext(
    allocator: Allocator,
    io_opt: ?std.Io,
    parent: Context,
    deadline_val: time.Time,
    timeout_cause: ?anyerror,
) !*DeadlineContext {
    const effective_io = io_opt orelse parentIo(parent);

    if (parent.deadline()) |parent_deadline| {
        if (parent_deadline.unixNano() <= deadline_val.unixNano()) {
            // Parent deadline is already earlier or equal; mirror Go's optimization
            // by using parent's deadline and avoiding an extra timer thread.
            const ctx = try allocator.create(DeadlineContext);
            ctx.* = .{
                .cancel_ctx = .{
                    .parent = parent,
                    .io = effective_io,
                    .has_notifier = (effective_io != null),
                },
                .deadline_val = parent_deadline,
                .timeout_cause = null,
            };
            _ = parent.vtable.subscribe(parent.ptr, &ctx.cancel_ctx.parent_sub);
            return ctx;
        }
    }

    const ctx = try allocator.create(DeadlineContext);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .cancel_ctx = .{
            .parent = parent,
            .io = effective_io,
            .has_notifier = (effective_io != null),
        },
        .deadline_val = deadline_val,
        .timeout_cause = timeout_cause,
    };

    const subscribed = parent.vtable.subscribe(parent.ptr, &ctx.cancel_ctx.parent_sub);
    if (!subscribed) {
        return ctx;
    }
    errdefer parent.vtable.unsubscribe(parent.ptr, &ctx.cancel_ctx.parent_sub);

    if (io_opt) |io| {
        if (ctx.check(io)) {
            return ctx;
        }
        ctx.timer_thread = try std.Thread.spawn(.{}, DeadlineContext.timerMain, .{ ctx, io });
    }
    return ctx;
}

pub fn withDeadline(
    allocator: Allocator,
    parent: Context,
    deadline_val: time.Time,
) Allocator.Error!*DeadlineContext {
    return createDeadlineContext(allocator, null, parent, deadline_val, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn withDeadlineIo(
    allocator: Allocator,
    io: std.Io,
    parent: Context,
    deadline_val: time.Time,
) !*DeadlineContext {
    return createDeadlineContext(allocator, io, parent, deadline_val, null);
}

pub fn withDeadlineCauseIo(
    allocator: Allocator,
    io: std.Io,
    parent: Context,
    deadline_val: time.Time,
    timeout_cause: anyerror,
) !*DeadlineContext {
    return createDeadlineContext(allocator, io, parent, deadline_val, timeout_cause);
}

pub fn withTimeout(
    allocator: Allocator,
    io: std.Io,
    parent: Context,
    timeout_dur: time.Duration,
) !*DeadlineContext {
    const target_deadline = time.Time.now(io).add(timeout_dur);
    return createDeadlineContext(allocator, io, parent, target_deadline, null);
}

pub fn withTimeoutCause(
    allocator: Allocator,
    io: std.Io,
    parent: Context,
    timeout_dur: time.Duration,
    timeout_cause: anyerror,
) !*DeadlineContext {
    const target_deadline = time.Time.now(io).add(timeout_dur);
    return createDeadlineContext(allocator, io, parent, target_deadline, timeout_cause);
}

// --- AfterFunc ---
pub const AfterFuncHandle = struct {
    ctx: Context,
    sub: Subscriber,
    callback: *const fn (arg: ?*anyopaque) void,
    arg: ?*anyopaque,
    thread: ?std.Thread = null,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn onCancel(
        sub_ptr: *Subscriber,
        _: Error,
        _: ?anyerror,
        _: ?std.Io,
    ) void {
        const self: *AfterFuncHandle = @fieldParentPtr("sub", sub_ptr);
        if (self.stopped.load(.acquire)) return;
        if (self.fired.swap(true, .acq_rel)) return;
        self.thread = std.Thread.spawn(.{}, runCallback, .{self}) catch {
            self.callback(self.arg);
            return;
        };
    }

    fn runCallback(self: *AfterFuncHandle) void {
        self.callback(self.arg);
    }

    /// Attempts to stop the registered callback from running.
    /// Returns `true` if the call stopped the callback before it started,
    /// matching Go's `context.AfterFunc`.
    pub fn stop(self: *AfterFuncHandle) bool {
        if (self.stopped.swap(true, .acq_rel)) return false;
        self.ctx.vtable.unsubscribe(self.ctx.ptr, &self.sub);
        return !self.fired.load(.acquire);
    }

    pub fn deinit(self: *AfterFuncHandle, allocator: Allocator) void {
        _ = self.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        allocator.destroy(self);
    }
};

/// Arranges to call `func(arg)` in its own thread after `ctx` is done.
/// If `ctx` is already done, `func(arg)` is started immediately.
pub fn afterFunc(
    allocator: Allocator,
    ctx: Context,
    func: *const fn (arg: ?*anyopaque) void,
    arg: ?*anyopaque,
) Allocator.Error!*AfterFuncHandle {
    const handle = try allocator.create(AfterFuncHandle);
    handle.* = .{
        .ctx = ctx,
        .sub = .{ .on_cancel = AfterFuncHandle.onCancel },
        .callback = func,
        .arg = arg,
    };
    _ = ctx.vtable.subscribe(ctx.ptr, &handle.sub);
    return handle;
}

test "context.Background and WithCancel" {
    const testing = std.testing;

    const bg = background();
    try testing.expect(!bg.done());
    try testing.expect(bg.err() == null);
    try testing.expect(bg.cause() == null);
    try testing.expect(bg.deadline() == null);

    var cancel_node = try withCancel(testing.allocator, bg);
    defer cancel_node.deinit(testing.allocator);

    const ctx = cancel_node.context();
    try testing.expect(!ctx.done());

    cancel_node.cancel();
    try testing.expect(ctx.done());
    try testing.expectEqual(Error.Canceled, ctx.err().?);
    try testing.expectEqual(@as(?anyerror, Error.Canceled), ctx.cause());
}

test "context.WithValue chain and valueAs" {
    const testing = std.testing;

    const bg = background();
    const trace_id: usize = 12345;
    const user_name: []const u8 = "alice";

    var v1 = try withValue(testing.allocator, bg, "trace_id", &trace_id);
    defer v1.deinit(testing.allocator);

    var v2 = try withValue(testing.allocator, v1.context(), "user", &user_name);
    defer v2.deinit(testing.allocator);

    const ctx = v2.context();

    const user_ptr = ctx.valueAs([]const u8, "user").?;
    try testing.expectEqualStrings("alice", user_ptr.*);

    const trace_val = ctx.valueAs(usize, "trace_id").?;
    try testing.expectEqual(@as(usize, 12345), trace_val.*);
    try testing.expect(ctx.valueAs(usize, "missing") == null);
}

test "context.WithDeadline" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bg = background();
    const target_time = time.Time.unix(0, 0);

    var dl_node = try withDeadline(testing.allocator, bg, target_time);
    defer dl_node.deinit(testing.allocator);

    const ctx = dl_node.context();
    try testing.expect(dl_node.check(io));
    try testing.expect(ctx.done());
    try testing.expectEqual(Error.DeadlineExceeded, ctx.err().?);
}

test "context refreshes deadlines through injected io" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const expired = time.Time.unix(0, 0);
    var node = try withDeadline(testing.allocator, background(), expired);
    defer node.deinit(testing.allocator);

    const ctx = node.context();
    try testing.expect(ctx.doneWithIo(io));
    try testing.expectEqual(Error.DeadlineExceeded, ctx.errWithIo(io).?);
}

test "context deadline uses the earliest parent deadline" {
    const testing = std.testing;

    const parent_deadline = time.Time.unix(10, 0);
    const child_deadline = time.Time.unix(20, 0);

    var parent = try withDeadline(testing.allocator, background(), parent_deadline);
    defer parent.deinit(testing.allocator);
    var child = try withDeadline(testing.allocator, parent.context(), child_deadline);
    defer child.deinit(testing.allocator);

    try testing.expectEqual(parent_deadline.unixNano(), child.context().deadline().?.unixNano());
}

test "context.withCancelIo wakes blocking wait and propagates to children" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var parent = try withCancelIo(testing.allocator, io, background());
    defer parent.deinit(testing.allocator);

    var child = try withCancelIo(testing.allocator, io, parent.context());
    defer child.deinit(testing.allocator);

    const State = struct {
        ctx: Context,
        io: std.Io,
        got_err: ?WaitError = null,

        fn waiter(self: *@This()) void {
            self.ctx.wait(self.io) catch |e| {
                self.got_err = e;
            };
        }
    };

    var state = State{ .ctx = child.context(), .io = io };
    const t = try std.Thread.spawn(.{}, State.waiter, .{&state});

    try io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    parent.cancel();
    t.join();

    try testing.expectEqual(@as(?WaitError, Error.Canceled), state.got_err);
    try testing.expect(child.context().done());
}

test "context.withTimeout automatically expires and wakes wait without check()" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var node = try withTimeout(
        testing.allocator,
        io,
        background(),
        @fromBackingInt(@intCast(20 * std.time.ns_per_ms)),
    );
    defer node.deinit(testing.allocator);

    try testing.expectError(Error.DeadlineExceeded, node.context().wait(io));
    try testing.expect(node.context().done());
}

test "context.withTimeout early deinit does not wait for remaining timeout" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const start = time.Time.now(io);
    var node = try withTimeout(
        testing.allocator,
        io,
        background(),
        @fromBackingInt(@intCast(5 * std.time.ns_per_s)),
    );
    node.deinit(testing.allocator);
    const elapsed = time.Time.now(io).sub(start);
    try testing.expect(elapsed.nanoseconds() < 500 * std.time.ns_per_ms);
}

test "context.withCancelCause and withTimeoutCause" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const CustomErr = error{ UpstreamShutDown, RequestTimedOut };

    var c = try withCancelCauseIo(testing.allocator, io, background());
    defer c.deinit(testing.allocator);
    c.cancelWithCause(CustomErr.UpstreamShutDown);

    try testing.expectEqual(Error.Canceled, c.context().err().?);
    try testing.expectEqual(@as(?anyerror, CustomErr.UpstreamShutDown), cause(c.context()));

    var t = try withTimeoutCause(
        testing.allocator,
        io,
        background(),
        @fromBackingInt(@intCast(15 * std.time.ns_per_ms)),
        CustomErr.RequestTimedOut,
    );
    defer t.deinit(testing.allocator);

    try testing.expectError(Error.DeadlineExceeded, t.context().wait(io));
    try testing.expectEqual(@as(?anyerror, CustomErr.RequestTimedOut), cause(t.context()));
}

test "context.withoutCancel detaches cancellation but preserves values" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const val: u32 = 99;
    var v = try withValue(testing.allocator, background(), "k", &val);
    defer v.deinit(testing.allocator);

    var parent = try withCancelIo(testing.allocator, io, v.context());
    defer parent.deinit(testing.allocator);

    var detached = try withoutCancel(testing.allocator, parent.context());
    defer detached.deinit(testing.allocator);

    parent.cancel();

    try testing.expect(parent.context().done());
    try testing.expect(!detached.context().done());
    try testing.expect(detached.context().err() == null);
    try testing.expect(detached.context().deadline() == null);
    try testing.expectEqual(@as(u32, 99), detached.context().valueAs(u32, "k").?.*);
}

test "context.afterFunc fires on cancel and stop prevents firing" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Counter = struct {
        called: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        done_ev: std.Io.Event = .unset,
        io: std.Io,

        fn cb(arg: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg.?));
            _ = self.called.fetchAdd(1, .acq_rel);
            self.done_ev.set(self.io);
        }
    };

    var c1 = try withCancelIo(testing.allocator, io, background());
    defer c1.deinit(testing.allocator);

    var counter1 = Counter{ .io = io };
    var h1 = try afterFunc(testing.allocator, c1.context(), Counter.cb, &counter1);
    defer h1.deinit(testing.allocator);

    c1.cancel();
    try counter1.done_ev.wait(io);
    try testing.expectEqual(@as(u32, 1), counter1.called.load(.acquire));
    try testing.expect(!h1.stop());

    var c2 = try withCancelIo(testing.allocator, io, background());
    defer c2.deinit(testing.allocator);

    var counter2 = Counter{ .io = io };
    var h2 = try afterFunc(testing.allocator, c2.context(), Counter.cb, &counter2);
    defer h2.deinit(testing.allocator);

    try testing.expect(h2.stop());
    c2.cancel();
    try testing.expectEqual(@as(u32, 0), counter2.called.load(.acquire));
}

test "context.wait works with std.Io.Select" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cancel_node = try withCancelIo(testing.allocator, io, background());
    defer cancel_node.deinit(testing.allocator);

    var work_ev: std.Io.Event = .unset;

    const Outcome = union(enum) {
        canceled: WaitError!void,
        work_done: std.Io.Cancelable!void,
    };

    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.async(.canceled, Context.wait, .{ cancel_node.context(), io });
    sel.async(.work_done, std.Io.Event.wait, .{ &work_ev, io });

    cancel_node.cancel();

    const winner = try sel.await();
    sel.cancelDiscard();

    switch (winner) {
        .canceled => |res| try testing.expectError(Error.Canceled, res),
        .work_done => return error.UnexpectedTestFailure,
    }
}

test "context.withCancel child inherits parent io and wakes wait on direct cancel" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var parent = try withCancelIo(testing.allocator, io, background());
    defer parent.deinit(testing.allocator);

    // Child created without explicit io should inherit parent's io so direct
    // child.cancel() still wakes a waiter blocked on futex.
    var child = try withCancel(testing.allocator, parent.context());
    defer child.deinit(testing.allocator);

    const State = struct {
        ctx: Context,
        io: std.Io,
        got_err: ?WaitError = null,

        fn waiter(self: *@This()) void {
            self.ctx.wait(self.io) catch |e| {
                self.got_err = e;
            };
        }
    };

    var state = State{ .ctx = child.context(), .io = io };
    const t = try std.Thread.spawn(.{}, State.waiter, .{&state});

    try io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake);
    child.cancel();
    t.join();

    try testing.expectEqual(@as(?WaitError, Error.Canceled), state.got_err);
}

test "context concurrent parent cancel and child deinit stress" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (0..64) |_| {
        var parent = try withCancelIo(testing.allocator, io, background());
        defer parent.deinit(testing.allocator);

        const c1 = try withCancel(testing.allocator, parent.context());
        const c2 = try withCancel(testing.allocator, parent.context());
        const c3 = try withCancel(testing.allocator, parent.context());

        const Canceler = struct {
            fn runParent(p: *CancelContext) void {
                p.cancel();
            }
            fn destroyChild(c: *CancelContext, alloc: Allocator) void {
                c.deinit(alloc);
            }
        };

        const t_p = try std.Thread.spawn(.{}, Canceler.runParent, .{parent});
        const t_c1 = try std.Thread.spawn(.{}, Canceler.destroyChild, .{ c1, testing.allocator });
        const t_c2 = try std.Thread.spawn(.{}, Canceler.destroyChild, .{ c2, testing.allocator });
        const t_c3 = try std.Thread.spawn(.{}, Canceler.destroyChild, .{ c3, testing.allocator });

        t_p.join();
        t_c1.join();
        t_c2.join();
        t_c3.join();
    }
}

test "context unsubscribe waits for in-flight notification and allows same-thread reentrancy" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Cross-thread barrier: `unsubscribe` must wait until `cancelInternal`'s
    // notification loop finishes before returning, preventing UAF on `sub2`.
    {
        var parent = try withCancelIo(testing.allocator, io, background());
        defer parent.deinit(testing.allocator);

        const Probe = struct {
            io: std.Io,
            entered_ev: std.Io.Event = .unset,
            unsub_returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            saw_unsub_return_early: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            sub1: Subscriber = .{ .on_cancel = onSub1 },
            sub2: Subscriber = .{ .on_cancel = onSub2 },

            fn onSub1(
                sub: *Subscriber,
                _: Error,
                _: ?anyerror,
                _: ?std.Io,
            ) void {
                const self: *@This() = @fieldParentPtr("sub1", sub);
                self.entered_ev.set(self.io);
                self.io.sleep(std.Io.Duration.fromNanoseconds(15 * std.time.ns_per_ms), .awake) catch {};
                if (self.unsub_returned.load(.acquire)) {
                    self.saw_unsub_return_early.store(true, .release);
                }
            }

            fn onSub2(
                _: *Subscriber,
                _: Error,
                _: ?anyerror,
                _: ?std.Io,
            ) void {}

            fn unsubWorker(self: *@This(), p: Context) void {
                self.entered_ev.wait(self.io) catch return;
                p.vtable.unsubscribe(p.ptr, &self.sub2);
                self.unsub_returned.store(true, .release);
            }
        };

        var probe = Probe{ .io = io };
        const p_ctx = parent.context();
        try testing.expect(p_ctx.vtable.subscribe(p_ctx.ptr, &probe.sub2));
        try testing.expect(p_ctx.vtable.subscribe(p_ctx.ptr, &probe.sub1));

        const t = try std.Thread.spawn(.{}, Probe.unsubWorker, .{ &probe, p_ctx });
        parent.cancel();
        t.join();

        try testing.expect(!probe.saw_unsub_return_early.load(.acquire));
        try testing.expect(probe.unsub_returned.load(.acquire));
    }

    // 2. Same-thread reentrancy: calling `unsubscribe` from inside `on_cancel`
    // must not deadlock on `notify_mutex`.
    {
        var parent = try withCancelIo(testing.allocator, io, background());
        defer parent.deinit(testing.allocator);

        const Reentrant = struct {
            ctx: Context,
            called: bool = false,
            sub: Subscriber = .{ .on_cancel = onCancel },

            fn onCancel(
                sub: *Subscriber,
                _: Error,
                _: ?anyerror,
                _: ?std.Io,
            ) void {
                const self: *@This() = @fieldParentPtr("sub", sub);
                self.called = true;
                self.ctx.vtable.unsubscribe(self.ctx.ptr, &self.sub);
            }
        };

        const p_ctx = parent.context();
        var r = Reentrant{ .ctx = p_ctx };
        try testing.expect(p_ctx.vtable.subscribe(p_ctx.ptr, &r.sub));
        parent.cancel();
        try testing.expect(r.called);
    }
}
