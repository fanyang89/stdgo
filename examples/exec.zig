//! Example demonstrating stdgo os/exec package:
//! 1. Command execution and output capture
//! 2. Stdin piping via io.Reader into child process
//! 3. Context cancellation with timeout

const std = @import("std");
const stdgo = @import("stdgo");
const os = stdgo.os;
const context = stdgo.context;
const bytes = stdgo.bytes;
const io_mod = stdgo.io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    std.debug.print("=== stdgo: os/exec Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. Basic command output
    // -------------------------------------------------------------
    std.debug.print("1. os.exec.command with output():\n", .{});

    const echo_args = [_][]const u8{ "echo", "Hello from stdgo os/exec!" };
    var cmd1 = os.exec.command(gpa, &echo_args);
    const out1 = try cmd1.output(io);
    defer gpa.free(out1);
    std.debug.print("   Output: {s}", .{out1});

    // -------------------------------------------------------------
    // 2. Piping stdin to child process
    // -------------------------------------------------------------
    std.debug.print("\n2. Stdin piping via bytes.Reader into cat:\n", .{});

    const input_msg = "Piped standard input stream into child process\n";
    var in_reader = bytes.Reader.init(input_msg);

    const cat_args = [_][]const u8{"cat"};
    var cmd2 = os.exec.command(gpa, &cat_args);
    cmd2.stdin = in_reader.reader();

    const out2 = try cmd2.output(io);
    defer gpa.free(out2);
    std.debug.print("   Cat output: {s}", .{out2});

    // -------------------------------------------------------------
    // 3. CommandContext with cancellation
    // -------------------------------------------------------------
    std.debug.print("\n3. os.exec.commandContext cancellation:\n", .{});

    const bg = context.background();
    var cancel_ctx = try context.withCancel(gpa, bg);
    defer gpa.destroy(cancel_ctx);

    const sleep_args = [_][]const u8{ "sleep", "5" };
    var cmd3 = os.exec.commandContext(gpa, cancel_ctx.context(), &sleep_args);

    // Cancel in background thread after 20ms
    const Watcher = struct {
        fn cancelSoon(c: *context.CancelContext, s_io: std.Io) void {
            s_io.sleep(std.Io.Duration.fromNanoseconds(20 * std.time.ns_per_ms), .awake) catch {};
            c.cancel();
        }
    };
    const t = try std.Thread.spawn(.{}, Watcher.cancelSoon, .{ cancel_ctx, io });
    defer t.join();

    if (cmd3.run(io)) |_| {
        std.debug.print("   Unexpected: sleep completed without cancellation\n", .{});
    } else |err| {
        std.debug.print("   Successfully canceled: {}\n", .{err});
    }

    std.debug.print("\nos/exec example finished successfully.\n", .{});
}
