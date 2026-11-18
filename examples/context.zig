//! Example demonstrating stdgo context package:
//! 1. context.background(): Root context
//! 2. withValue() / valueAs(): Request-scoped key-value propagation
//! 3. withCancelCauseIo(): Manual cancellation with custom cause
//! 4. withTimeout() + wait(io): Automatic deadline expiration & blocking wait

const std = @import("std");
const stdgo = @import("stdgo");
const context = stdgo.context;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    std.debug.print("=== stdgo: context Lifecycle & Propagation Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. context.withValue + valueAs: Request metadata propagation
    // -------------------------------------------------------------
    std.debug.print("1. context.withValue (Metadata Propagation):\n", .{});
    const root_ctx = context.background();

    const trace_id: []const u8 = "trace-uuid-9876-xyz";
    const user_role: []const u8 = "admin-role";

    const ctx_with_trace = try context.withValue(gpa, root_ctx, "trace_id", &trace_id);
    defer ctx_with_trace.deinit(gpa);
    const ctx_with_auth = try context.withValue(gpa, ctx_with_trace.context(), "role", &user_role);
    defer ctx_with_auth.deinit(gpa);

    if (ctx_with_auth.context().valueAs([]const u8, "trace_id")) |tid| {
        std.debug.print("   Retrieved trace_id from deep context: \"{s}\"\n", .{tid.*});
    }
    if (ctx_with_auth.context().valueAs([]const u8, "role")) |r| {
        std.debug.print("   Retrieved role from deep context:     \"{s}\"\n\n", .{r.*});
    }

    // -------------------------------------------------------------
    // 2. context.withCancelCauseIo: Cancellation with cause
    // -------------------------------------------------------------
    std.debug.print("2. context.withCancelCauseIo (Coordinated Cancellation):\n", .{});
    const ShutdownErr = error{UserRequestedShutdown};
    var cancel_ctx = try context.withCancelCauseIo(gpa, io, ctx_with_auth.context());
    defer cancel_ctx.deinit(gpa);
    const c_ctx = cancel_ctx.context();

    std.debug.print("   Initial state -> done: {any}, err: {any}\n", .{ c_ctx.done(), c_ctx.err() });

    std.debug.print("   Triggering cancellation with custom cause...\n", .{});
    cancel_ctx.cancelWithCause(ShutdownErr.UserRequestedShutdown);

    std.debug.print(
        "   After cancel  -> done: {any}, err: {any}, cause: {any}\n\n",
        .{ c_ctx.done(), c_ctx.err(), context.cause(c_ctx) },
    );

    // -------------------------------------------------------------
    // 3. context.withTimeout + wait(io): Automatic expiration
    // -------------------------------------------------------------
    std.debug.print("3. context.withTimeout + wait(io):\n", .{});
    var timeout_ctx = try context.withTimeout(
        gpa,
        io,
        root_ctx,
        @fromBackingInt(@as(i64, 30 * std.time.ns_per_ms)),
    );
    defer timeout_ctx.deinit(gpa);

    const wait_res = timeout_ctx.context().wait(io);
    std.debug.print("   wait(io) returned: {any}\n", .{wait_res});

    std.debug.print("\n=== context demo completed successfully! ===\n", .{});
}
