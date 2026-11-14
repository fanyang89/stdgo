//! Example demonstrating stdgo.database.sql:
//! Generic database connection pooling, transactions, prepared statements, and metrics.

const std = @import("std");
const stdgo = @import("stdgo");
const sql = stdgo.database.sql;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo database/sql Connection Pool & Transaction Demo ===\n\n", .{});

    // 1. Initialize In-Memory Mock Driver
    var state = sql.MockDriver.State.init(allocator);
    defer state.deinit();

    var mock = sql.MockDriver{ .state = &state };

    // 2. Open DB Connection Pool
    const db = try sql.DB.open(allocator, mock.driver(), "mock://cluster-primary.internal:5432/production");
    defer db.close();

    // Configure connection pool parameters
    db.setMaxOpenConns(5);
    db.setMaxIdleConns(2);

    std.debug.print("1. DB Pool initialized (DSN: {s})\n", .{db.dsn});

    // 3. Ping Database
    try db.ping();
    std.debug.print("2. Ping successful. Open Conns: {d}, Idle: {d}\n\n", .{
        db.stats().open_connections,
        db.stats().idle,
    });

    // 4. Execute Queries (INSERT / UPDATE)
    const res = try db.exec(
        "INSERT INTO users (name, role, status) VALUES (?, ?, ?)",
        &.{
            sql.Value{ .string = "diana" },
            sql.Value{ .string = "secops" },
            sql.Value{ .string = "active" },
        },
    );
    std.debug.print("3. db.exec executed:\n   -> Last Insert ID: {d}\n   -> Rows Affected:  {d}\n\n", .{
        res.lastInsertId(),
        res.rowsAffected(),
    });

    // 5. Query Rows (SELECT)
    std.debug.print("4. db.query executed (SELECT id, name, role FROM users):\n", .{});
    var rows = try db.query("SELECT id, name, role FROM users", &.{});
    defer rows.close();

    const cols = rows.columns();
    std.debug.print("   Columns: [", .{});
    for (cols, 0..) |col, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{col});
    }
    std.debug.print("]\n", .{});

    var row_record: [3]sql.Value = undefined;
    while (rows.next(&row_record)) {
        std.debug.print("   Row -> ID: {d}, Name: '{s}', Role: '{s}'\n", .{
            row_record[0].int,
            row_record[1].string,
            row_record[2].string,
        });
    }
    std.debug.print("\n", .{});

    // 6. Transactions (Commit & Rollback)
    std.debug.print("5. Transactions (ACID Commit & Rollback):\n", .{});
    // Successful transaction commit:
    {
        var tx = try db.begin();
        _ = try tx.exec("UPDATE accounts SET balance = balance - 250 WHERE id = 1", &.{});
        _ = try tx.exec("UPDATE accounts SET balance = balance + 250 WHERE id = 2", &.{});
        try tx.commit();
        std.debug.print("   -> Transaction #1 committed successfully!\n", .{});
    }

    // Aborted transaction rollback:
    {
        var tx = try db.begin();
        _ = try tx.exec("UPDATE inventory SET stock = stock - 10 WHERE item_id = 99", &.{});
        // Something failed during checkout, rollback:
        try tx.rollback();
        std.debug.print("   -> Transaction #2 rolled back cleanly on error!\n\n", .{});
    }

    // 7. Concurrent Connection Contention
    std.debug.print("6. Concurrent Workers Pool Contention (4 threads competing for pool):\n", .{});
    const Worker = struct {
        fn workerThread(db_handle: *sql.DB) void {
            for (0..10) |_| {
                const pc = db_handle.conn() catch return;
                defer pc.release();
                var stmt = pc.raw.prepare("SELECT 1") catch continue;
                defer stmt.close();
                _ = stmt.exec(&.{}) catch {};
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});
    const t2 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});
    const t3 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});
    const t4 = try std.Thread.spawn(.{}, Worker.workerThread, .{db});

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    // 8. DB Pool Statistics
    const st = db.stats();
    std.debug.print("7. Final Pool Statistics:\n", .{});
    std.debug.print("   -> Max Open:          {d}\n", .{st.max_open_connections});
    std.debug.print("   -> Current Open:      {d}\n", .{st.open_connections});
    std.debug.print("   -> In-Use:            {d}\n", .{st.in_use});
    std.debug.print("   -> Idle in Pool:      {d}\n", .{st.idle});
    std.debug.print("   -> Total Waits:       {d}\n", .{st.wait_count});
    std.debug.print("   -> Max-Idle Closed:   {d}\n", .{st.max_idle_closed});

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
