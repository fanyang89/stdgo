const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../io.zig");
const context = @import("../context.zig");
const bytes_mod = @import("../bytes.zig");
const sync = @import("../sync.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Child = std.process.Child;

pub const Error = error{
    ExitError,
    CommandFailed,
    StreamTooLong,
} || std.process.SpawnError || Child.WaitError || Allocator.Error || context.Error;

/// Cmd represents an external command being prepared or run.
pub const Cmd = struct {
    allocator: Allocator,
    argv: []const []const u8,
    dir: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    ctx: ?context.Context = null,

    stdin: ?*io_mod.Reader = null,
    stdout: ?*io_mod.Writer = null,
    stderr: ?*io_mod.Writer = null,

    /// Run starts the specified command and waits for it to complete.
    pub fn run(self: *Cmd, io: Io) Error!Child.Term {
        if (self.ctx) |c| {
            if (c.err()) |e| return e;
        }

        const stdin_mode: std.process.SpawnOptions.StdIo = if (self.stdin != null) .pipe else .inherit;
        const stdout_mode: std.process.SpawnOptions.StdIo = if (self.stdout != null) .pipe else .inherit;
        const stderr_mode: std.process.SpawnOptions.StdIo = if (self.stderr != null) .pipe else .inherit;

        const cwd_mode: Child.Cwd = if (self.dir) |d| .{ .path = d } else .inherit;

        const State = struct {
            mutex: sync.Mutex = .{},
            child: Child,
            exited: bool = false,
        };

        var state = State{
            .child = try std.process.spawn(io, .{
                .argv = self.argv,
                .cwd = cwd_mode,
                .environ_map = self.environ_map,
                .stdin = stdin_mode,
                .stdout = stdout_mode,
                .stderr = stderr_mode,
            }),
            .exited = false,
        };

        // Watchdog thread for Context cancellation
        var watchdog_done = std.atomic.Value(bool).init(false);
        var watchdog_thread: ?std.Thread = null;
        if (self.ctx) |ctx_val| {
            const Watchdog = struct {
                fn runWatchdog(done_ptr: *std.atomic.Value(bool), s_ptr: *State, c_io: Io, c_ctx: context.Context) void {
                    while (!done_ptr.load(.acquire)) {
                        if (c_ctx.err() != null) {
                            s_ptr.mutex.lock();
                            defer s_ptr.mutex.unlock();
                            if (!s_ptr.exited) {
                                // Note: We do NOT call `s_ptr.child.kill(c_io)` here because `child.kill`
                                // synchronously calls `wait4` to reap the process. Doing so from this watchdog
                                // thread while the main thread is concurrently blocked in `child.wait(io)` would
                                // cause both threads to invoke `wait4` on the same PID, triggering an ECHILD race
                                // and panicking with "programmer bug caused syscall error: CHILD (Double-free)".
                                // Instead, send an asynchronous termination signal (SIGTERM on POSIX) without
                                // reaping, letting the main thread's `child.wait(io)` safely reap and collect status.
                                if (builtin.os.tag != .windows) {
                                    if (s_ptr.child.id) |pid| {
                                        _ = std.posix.kill(pid, .TERM) catch {};
                                    }
                                } else {
                                    if (s_ptr.child.id) |handle| {
                                        _ = std.os.windows.ntdll.NtTerminateProcess(handle, 1);
                                    }
                                }
                            }
                            break;
                        }
                        c_io.sleep(std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
                    }
                }
            };
            watchdog_thread = std.Thread.spawn(.{}, Watchdog.runWatchdog, .{ &watchdog_done, &state, io, ctx_val }) catch null;
        }

        // Pipe stdin if provided
        if (self.stdin) |r_in| {
            if (state.child.stdin) |*in_file| {
                var w_scratch: [2048]u8 = undefined;
                var file_w = in_file.writerStreaming(io, &w_scratch);
                _ = io_mod.copy(&file_w.interface, r_in) catch {};
                file_w.interface.flush() catch {};
                in_file.close(io);
                state.child.stdin = null;
            }
        }

        // Pipe stdout if provided
        if (self.stdout) |w_out| {
            if (state.child.stdout) |*out_file| {
                var r_scratch: [2048]u8 = undefined;
                var file_r = out_file.readerStreaming(io, &r_scratch);
                _ = io_mod.copy(w_out, &file_r.interface) catch {};
                w_out.flush() catch {};
                out_file.close(io);
                state.child.stdout = null;
            }
        }

        // Pipe stderr if provided
        if (self.stderr) |w_err| {
            if (state.child.stderr) |*err_file| {
                var r_scratch: [2048]u8 = undefined;
                var file_r = err_file.readerStreaming(io, &r_scratch);
                _ = io_mod.copy(w_err, &file_r.interface) catch {};
                w_err.flush() catch {};
                err_file.close(io);
                state.child.stderr = null;
            }
        }

        const term = blk: {
            state.mutex.lock();
            if (state.exited) {
                state.mutex.unlock();
                return Error.ExitError;
            }
            state.mutex.unlock();

            const t = try state.child.wait(io);
            state.mutex.lock();
            state.exited = true;
            state.mutex.unlock();
            break :blk t;
        };

        watchdog_done.store(true, .release);
        if (watchdog_thread) |wt| {
            wt.join();
        }

        if (self.ctx) |c| {
            if (c.err()) |e| return e;
        }

        if (!term.success()) {
            return Error.ExitError;
        }

        return term;
    }

    /// Output runs the command and returns its standard output.
    pub fn output(self: *Cmd, io: Io) Error![]u8 {
        var out_buf = bytes_mod.Buffer.init(self.allocator);
        errdefer out_buf.deinit();

        self.stdout = out_buf.writer();
        _ = try self.run(io);

        return try out_buf.toOwnedSlice();
    }

    /// CombinedOutput runs the command and returns its combined standard output and standard error.
    pub fn combinedOutput(self: *Cmd, io: Io) Error![]u8 {
        var combined_buf = bytes_mod.Buffer.init(self.allocator);
        errdefer combined_buf.deinit();

        self.stdout = combined_buf.writer();
        self.stderr = combined_buf.writer();
        _ = try self.run(io);

        return try combined_buf.toOwnedSlice();
    }
};

/// Command returns the Cmd struct to execute the named program with the given arguments.
pub fn command(allocator: Allocator, argv: []const []const u8) Cmd {
    return .{
        .allocator = allocator,
        .argv = argv,
    };
}

/// CommandContext is like Command but includes a context.
pub fn commandContext(allocator: Allocator, ctx: context.Context, argv: []const []const u8) Cmd {
    return .{
        .allocator = allocator,
        .argv = argv,
        .ctx = ctx,
    };
}

test "os.exec: command and output" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv = [_][]const u8{ "echo", "hello stdgo exec" };
    var cmd = command(testing.allocator, &argv);
    const out = try cmd.output(io);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "hello stdgo exec") != null);
}

test "os.exec: stdin piping via bytes.Reader" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const input_text = "pipe through standard input into cat\n";
    var r = bytes_mod.Reader.init(input_text);

    const argv = [_][]const u8{"cat"};
    var cmd = command(testing.allocator, &argv);
    cmd.stdin = r.reader();

    const out = try cmd.output(io);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(input_text, out);
}

test "os.exec: commandContext cancellation" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bg = context.background();
    var cancel_ctx = try context.withCancel(testing.allocator, bg);
    defer testing.allocator.destroy(cancel_ctx);

    const argv = [_][]const u8{ "sleep", "10" };
    var cmd = commandContext(testing.allocator, cancel_ctx.context(), &argv);

    // Cancel after 20ms
    const Killer = struct {
        fn cancelAfterDelay(ctx_cancel: *context.CancelContext, k_io: Io) void {
            k_io.sleep(std.Io.Duration.fromNanoseconds(20 * std.time.ns_per_ms), .awake) catch {};
            ctx_cancel.cancel();
        }
    };
    const t = try std.Thread.spawn(.{}, Killer.cancelAfterDelay, .{ cancel_ctx, io });
    defer t.join();

    const res = cmd.run(io);
    try testing.expectError(error.Canceled, res);
}
