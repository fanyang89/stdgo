//! Example demonstrating real SQLite integration with stdgo.database.sql.
//! Requires building with '-Dsqlite=true'.

const std = @import("std");
const stdgo = @import("stdgo");
const sql = stdgo.database.sql;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo database/sql Real SQLite Driver Demo ===\n\n", .{});

    // 1. Initialize SQLite Driver
    var sqlite_drv = sql.sqlite.SQLiteDriver.init(allocator);

    // 2. Open SQLite Database Pool
    // Supported DSN formats:
    // - ":memory:" (isolated in-memory database)
    // - "app.db" (local file database)
    // - "file:mem?mode=memory&cache=shared" (shared in-memory URI across pool connections)
    // - "sqlite://:memory:" or "sqlite3://app.db" (scheme prefixes are automatically stripped)
    const db = try sql.DB.open(allocator, init.io, sqlite_drv.driver(), ":memory:");
    defer db.close();

    db.setMaxOpenConns(5);
    db.setMaxIdleConns(2);

    std.debug.print("1. SQLite Database opened (DSN: ':memory:')\n", .{});

    // 3. Ping
    try db.ping();
    std.debug.print("2. Ping successful. Open: {d}, Idle: {d}\n\n", .{
        db.stats().open_connections,
        db.stats().idle,
    });

    // 4. Create Table
    // Executes DDL without parameters
    _ = try db.exec(
        \\CREATE TABLE products (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    price REAL NOT NULL,
        \\    in_stock INTEGER NOT NULL
        \\);
    , &.{});
    std.debug.print("3. Table 'products' created successfully.\n\n", .{});

    // 5. Insert Records via Parameterized Exec
    // Arguments are bound to positional '?' placeholders safely without SQL injection risk
    const r1 = try db.exec(
        "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
        &.{
            sql.Value{ .string = "Mechanical Keyboard" },
            sql.Value{ .float = 129.99 },
            sql.Value{ .int = 1 },
        },
    );
    std.debug.print("4. Inserted item #1 -> ID: {d}, Rows Affected: {d}\n", .{
        r1.lastInsertId(),
        r1.rowsAffected(),
    });

    const r2 = try db.exec(
        "INSERT INTO products (name, price, in_stock) VALUES (?, ?, ?)",
        &.{
            sql.Value{ .string = "Ergonomic Mouse" },
            sql.Value{ .float = 79.50 },
            sql.Value{ .int = 1 },
        },
    );
    std.debug.print("   Inserted item #2 -> ID: {d}, Rows Affected: {d}\n\n", .{
        r2.lastInsertId(),
        r2.rowsAffected(),
    });

    // 6. Query Records (SELECT)
    // db.query obtains a pooled connection and prepares the statement.
    // The connection is held until rows.close() is called or rows are exhausted.
    std.debug.print("5. Querying 'products' table:\n", .{});
    var rows = try db.query("SELECT id, name, price, in_stock FROM products ORDER BY id ASC", &.{});
    defer rows.close();

    const cols = rows.columns();
    std.debug.print("   Columns: [", .{});
    for (cols, 0..) |col, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{col});
    }
    std.debug.print("]\n", .{});

    // Scan column values sequentially into the record buffer
    var record: [4]sql.Value = undefined;
    while (rows.next(&record)) {
        std.debug.print("   -> Product #{d}: '{s}' | ${d:.2} | in_stock: {s}\n", .{
            record[0].int,
            record[1].string,
            record[2].float,
            if (record[3].int == 1) "YES" else "NO",
        });
    }
    std.debug.print("\n", .{});

    // 7. Transaction with Commit
    // db.begin() reserves a dedicated connection from the pool.
    // All queries must be executed on the Tx handle (tx.exec/tx.query).
    // tx.commit() or tx.rollback() completes the transaction and returns the connection.
    {
        var tx = try db.begin();
        _ = try tx.exec("UPDATE products SET price = price * 0.9 WHERE id = 1", &.{});
        try tx.commit();
        std.debug.print("6. Discount transaction committed successfully!\n\n", .{});
    }

    // 8. Pool Stats
    const st = db.stats();
    std.debug.print("7. Pool Stats:\n", .{});
    std.debug.print("   -> Open Conns: {d}, Idle: {d}, In-Use: {d}\n", .{
        st.open_connections,
        st.idle,
        st.in_use,
    });

    std.debug.print("\n=== SQLite Demo Complete ===\n", .{});
}
