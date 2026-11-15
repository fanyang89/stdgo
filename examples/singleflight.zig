//! Example demonstrating stdgo.sync.SingleFlight (Group):
//! Eliminating thundering herds and duplicate concurrent work.

const std = @import("std");
const stdgo = @import("stdgo");
const SingleFlight = stdgo.sync.SingleFlight;

const BackendService = struct {
    fetch_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    io: std.Io,

    fn fetchProduct(self: *@This(), product_id: u32) ![]const u8 {
        const count = self.fetch_count.fetchAdd(1, .monotonic) + 1;
        std.debug.print("   [Backend Database] Executing heavy query for product_id={d} (total backend calls: {d})...\n", .{ product_id, count });
        // Simulate remote database latency cooperatively using injected std.Io
        self.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        return "Laptop Model X - $999.00";
    }
};

const ClientWorker = struct {
    client_id: usize,
    sf_group: *SingleFlight([]const u8),
    service: *BackendService,

    fn run(self: *@This()) void {
        const res = self.sf_group.do("product:101", BackendService.fetchProduct, .{ self.service, 101 }) catch |err| {
            std.debug.print("   Client #{d} error: {s}\n", .{ self.client_id, @errorName(err) });
            return;
        };

        std.debug.print("   Client #{d} received: \"{s}\" (shared with concurrent callers: {})\n", .{
            self.client_id,
            res.val,
            res.shared,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    std.debug.print("=== stdgo sync.SingleFlight Duplicate Suppression Demo ===\n\n", .{});

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var backend = BackendService{ .io = io };
    var sf = SingleFlight([]const u8).init(allocator);
    defer sf.deinit();

    std.debug.print("1. Spawning 5 concurrent clients requesting the same uncached key 'product:101'...\n", .{});

    var workers: [5]ClientWorker = undefined;
    var threads: [5]std.Thread = undefined;

    for (0..5) |i| {
        workers[i] = .{
            .client_id = i + 1,
            .sf_group = &sf,
            .service = &backend,
        };
        threads[i] = try std.Thread.spawn(.{}, ClientWorker.run, .{&workers[i]});
    }

    for (0..5) |i| {
        threads[i].join();
    }

    std.debug.print("\n-> Verification: 5 client requests finished with only {d} actual backend query executed!\n\n", .{
        backend.fetch_count.load(.monotonic),
    });

    // 2. Sequential call after completion creates a new flight
    std.debug.print("2. Sequential query for 'product:101' after previous flight finished:\n", .{});
    const res2 = try sf.do("product:101", BackendService.fetchProduct, .{ &backend, 101 });
    std.debug.print("   Sequential caller received: \"{s}\" (shared: {})\n", .{ res2.val, res2.shared });
    std.debug.print("   Total backend queries now: {d}\n\n", .{backend.fetch_count.load(.monotonic)});

    std.debug.print("=== Demo Complete ===\n", .{});
}
