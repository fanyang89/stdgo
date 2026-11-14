//! SQLite driver adapter for stdgo.database.sql using nDimensional/zig-sqlite.
//! This module is only active when the 'sqlite' build option is enabled (-Dsqlite=true).
//!
//! Provides a complete implementation of stdgo.database.sql.driver interfaces
//! (Driver, Conn, Stmt, Rows, Tx) wrapping SQLite's native C library.

const std = @import("std");
const build_options = @import("build_options");
const driver_pkg = @import("driver.zig");
const Allocator = std.mem.Allocator;
const Value = driver_pkg.Value;
const Result = driver_pkg.Result;

/// SQLiteDriver is the database/sql driver implementation for SQLite.
/// When compiled with -Dsqlite=false, accessing or initializing this struct
/// triggers a compile error explaining how to enable it.
pub const SQLiteDriver = if (!build_options.have_sqlite) struct {
    pub fn init(_: Allocator) @This() {
        @compileError("SQLite driver is disabled. Build with -Dsqlite=true to enable it.");
    }
} else struct {
    const sqlite = @import("sqlite");
    const c = sqlite.c;

    allocator: Allocator,

    /// Initializes a new SQLiteDriver instance with the given memory allocator.
    pub fn init(allocator: Allocator) SQLiteDriver {
        return .{ .allocator = allocator };
    }

    /// Returns the generic database/sql Driver interface wrapping this driver.
    pub fn driver(self: *SQLiteDriver) driver_pkg.Driver {
        return .{
            .ptr = self,
            .vtable = &.{
                .open = SQLiteDriver.open,
            },
        };
    }

    /// Opens a new SQLite connection.
    ///
    /// Supported DSN formats:
    /// - Standard in-memory: `":memory:"`
    /// - File paths: `"app.db"`, `"./data/app.db"`, `"/var/lib/sqlite.db"`
    /// - SQLite URI filenames: `"file:memdb1?mode=memory&cache=shared"`
    /// - Optional URL scheme prefixes (automatically stripped for user convenience):
    ///   `"sqlite://:memory:"`, `"sqlite3://app.db"`, `"sqlite:///path/to/db"`
    fn open(ctx: *anyopaque, dsn: []const u8) anyerror!driver_pkg.Conn {
        const self: *SQLiteDriver = @ptrCast(@alignCast(ctx));

        // Strip optional "sqlite://" or "sqlite3://" scheme prefixes if provided.
        // SQLite's native sqlite3_open_v2 expects a file path, ":memory:", or a "file:..." URI.
        var clean_dsn = dsn;
        if (std.mem.startsWith(u8, clean_dsn, "sqlite3://")) {
            clean_dsn = clean_dsn["sqlite3://".len..];
        } else if (std.mem.startsWith(u8, clean_dsn, "sqlite://")) {
            clean_dsn = clean_dsn["sqlite://".len..];
        }

        var db: ?*c.sqlite3 = null;
        const null_terminated_dsn = try self.allocator.alloc(u8, clean_dsn.len + 1);
        defer self.allocator.free(null_terminated_dsn);
        @memcpy(null_terminated_dsn[0..clean_dsn.len], clean_dsn);
        null_terminated_dsn[clean_dsn.len] = 0;

        // Open database with READWRITE, CREATE, and URI support
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_URI;
        const rc = c.sqlite3_open_v2(null_terminated_dsn.ptr, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close_v2(d);
            return error.SQLiteOpenFailed;
        }

        const conn = try self.allocator.create(SQLiteConn);
        conn.* = .{
            .allocator = self.allocator,
            .db = db.?,
        };

        return driver_pkg.Conn{
            .ptr = conn,
            .vtable = &.{
                .prepare = SQLiteConn.prepare,
                .close = SQLiteConn.close,
                .begin = SQLiteConn.begin,
                .ping = SQLiteConn.ping,
            },
        };
    }

    /// SQLiteConn wraps a live sqlite3 handle and implements driver_pkg.Conn.
    const SQLiteConn = struct {
        allocator: Allocator,
        db: *c.sqlite3,

        /// Prepares a SQL query statement for execution.
        fn prepare(ctx: *anyopaque, query: []const u8) anyerror!driver_pkg.Stmt {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));

            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, query.ptr, @intCast(query.len), &stmt, null);
            if (rc != c.SQLITE_OK) {
                return error.SQLitePrepareFailed;
            }

            const s = try self.allocator.create(SQLiteStmt);
            s.* = .{
                .allocator = self.allocator,
                .db = self.db,
                .stmt = stmt.?,
            };

            return driver_pkg.Stmt{
                .ptr = s,
                .vtable = &.{
                    .close = SQLiteStmt.close,
                    .numInput = SQLiteStmt.numInput,
                    .exec = SQLiteStmt.exec,
                    .query = SQLiteStmt.query,
                },
            };
        }

        /// Closes the underlying SQLite connection.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_close_v2(self.db);
            self.allocator.destroy(self);
        }

        /// Starts a new SQLite transaction ("BEGIN TRANSACTION").
        fn begin(ctx: *anyopaque) anyerror!driver_pkg.Tx {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            var errmsg: [*c]u8 = null;
            if (c.sqlite3_exec(self.db, "BEGIN TRANSACTION", null, null, &errmsg) != c.SQLITE_OK) {
                if (errmsg != null) c.sqlite3_free(errmsg);
                return error.SQLiteTxBeginFailed;
            }

            const tx = try self.allocator.create(SQLiteTx);
            tx.* = .{
                .allocator = self.allocator,
                .db = self.db,
            };

            return driver_pkg.Tx{
                .ptr = tx,
                .vtable = &.{
                    .commit = SQLiteTx.commit,
                    .rollback = SQLiteTx.rollback,
                },
            };
        }

        /// Verifies connection health by stepping a dummy "SELECT 1" statement.
        fn ping(ctx: *anyopaque) anyerror!void {
            const self: *SQLiteConn = @ptrCast(@alignCast(ctx));
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT 1", -1, &stmt, null) != c.SQLITE_OK) {
                return error.SQLitePingFailed;
            }
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
                return error.SQLitePingFailed;
            }
        }
    };

    /// SQLiteStmt wraps a prepared sqlite3_stmt handle and implements driver_pkg.Stmt.
    const SQLiteStmt = struct {
        allocator: Allocator,
        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,

        /// Finalizes the prepared statement handle and frees memory.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_finalize(self.stmt);
            self.allocator.destroy(self);
        }

        /// Returns the number of parameter placeholders in the prepared statement.
        fn numInput(ctx: *anyopaque) i64 {
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            return c.sqlite3_bind_parameter_count(self.stmt);
        }

        /// Resets bindings and binds positional parameters (?) to SQLite native types.
        fn bindArgs(stmt: *c.sqlite3_stmt, args: []const Value) anyerror!void {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);

            for (args, 1..) |arg, idx_usize| {
                const idx: c_int = @intCast(idx_usize);
                switch (arg) {
                    .null => {
                        if (c.sqlite3_bind_null(stmt, idx) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .int => |i| {
                        if (c.sqlite3_bind_int64(stmt, idx, i) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .float => |f| {
                        if (c.sqlite3_bind_double(stmt, idx, f) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .bool => |b| {
                        if (c.sqlite3_bind_int(stmt, idx, if (b) 1 else 0) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .string => |s| {
                        // SQLITE_STATIC is safe here because args stay valid for the duration of sqlite3_step
                        if (c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                    .bytes => |b| {
                        if (c.sqlite3_bind_blob(stmt, idx, b.ptr, @intCast(b.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.SQLiteBindFailed;
                    },
                }
            }
        }

        /// Executes a prepared query that does not return rows (e.g., INSERT, UPDATE, DELETE).
        fn exec(ctx: *anyopaque, args: []const Value) anyerror!Result {
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            try bindArgs(self.stmt, args);

            const step_rc = c.sqlite3_step(self.stmt);
            if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                return error.SQLiteExecFailed;
            }

            const last_id = c.sqlite3_last_insert_rowid(self.db);
            const rows_affected = c.sqlite3_changes(self.db);

            return Result{
                .last_insert_id = last_id,
                .rows_affected = rows_affected,
            };
        }

        /// Executes a query that returns rows (e.g., SELECT).
        fn query(ctx: *anyopaque, args: []const Value) anyerror!driver_pkg.Rows {
            const self: *SQLiteStmt = @ptrCast(@alignCast(ctx));
            try bindArgs(self.stmt, args);

            const rows = try self.allocator.create(SQLiteRows);
            rows.* = .{
                .allocator = self.allocator,
                .stmt = self.stmt,
            };

            return driver_pkg.Rows{
                .ptr = rows,
                .vtable = &.{
                    .columns = SQLiteRows.columns,
                    .next = SQLiteRows.next,
                    .close = SQLiteRows.close,
                },
            };
        }
    };

    /// SQLiteRows implements driver_pkg.Rows, iterating over result rows.
    const SQLiteRows = struct {
        allocator: Allocator,
        stmt: *c.sqlite3_stmt,
        cols_cached: ?[]const []const u8 = null,

        /// Retrieves and caches column names from the current result set.
        fn columns(ctx: *anyopaque) []const []const u8 {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            if (self.cols_cached) |cols| return cols;

            const count: usize = @intCast(c.sqlite3_column_count(self.stmt));
            var col_list = self.allocator.alloc([]const u8, count) catch return &.{};
            for (0..count) |i| {
                const name_ptr = c.sqlite3_column_name(self.stmt, @intCast(i));
                col_list[i] = if (name_ptr != null) std.mem.span(name_ptr) else "";
            }
            self.cols_cached = col_list;
            return col_list;
        }

        /// Advances the cursor to the next row, decoding SQLite column types into dest.
        /// Returns true if a row was retrieved, false on completion or failure.
        fn next(ctx: *anyopaque, dest: []Value) bool {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            const rc = c.sqlite3_step(self.stmt);
            if (rc != c.SQLITE_ROW) return false;

            const col_count: usize = @intCast(c.sqlite3_column_count(self.stmt));
            const limit = @min(dest.len, col_count);

            for (0..limit) |i| {
                const col_idx: c_int = @intCast(i);
                const col_type = c.sqlite3_column_type(self.stmt, col_idx);
                dest[i] = switch (col_type) {
                    c.SQLITE_INTEGER => Value{ .int = c.sqlite3_column_int64(self.stmt, col_idx) },
                    c.SQLITE_FLOAT => Value{ .float = c.sqlite3_column_double(self.stmt, col_idx) },
                    c.SQLITE_TEXT => blk: {
                        const text_ptr = c.sqlite3_column_text(self.stmt, col_idx);
                        const bytes_len = c.sqlite3_column_bytes(self.stmt, col_idx);
                        if (text_ptr == null) break :blk Value.null;
                        break :blk Value{ .string = text_ptr[0..@intCast(bytes_len)] };
                    },
                    c.SQLITE_BLOB => blk: {
                        const blob_ptr: [*c]const u8 = @ptrCast(c.sqlite3_column_blob(self.stmt, col_idx));
                        const bytes_len = c.sqlite3_column_bytes(self.stmt, col_idx);
                        if (blob_ptr == null) break :blk Value.null;
                        break :blk Value{ .bytes = blob_ptr[0..@intCast(bytes_len)] };
                    },
                    c.SQLITE_NULL => Value.null,
                    else => Value.null,
                };
            }
            return true;
        }

        /// Resets statement cursor, frees cached column names, and releases row memory.
        fn close(ctx: *anyopaque) void {
            const self: *SQLiteRows = @ptrCast(@alignCast(ctx));
            _ = c.sqlite3_reset(self.stmt);
            if (self.cols_cached) |cols| {
                self.allocator.free(cols);
            }
            self.allocator.destroy(self);
        }
    };

    /// SQLiteTx manages an in-progress transaction, handling COMMIT and ROLLBACK.
    const SQLiteTx = struct {
        allocator: Allocator,
        db: *c.sqlite3,

        /// Commits the active transaction ("COMMIT").
        fn commit(ctx: *anyopaque) anyerror!void {
            const self: *SQLiteTx = @ptrCast(@alignCast(ctx));
            defer self.allocator.destroy(self);
            var errmsg: [*c]u8 = null;
            if (c.sqlite3_exec(self.db, "COMMIT", null, null, &errmsg) != c.SQLITE_OK) {
                if (errmsg != null) c.sqlite3_free(errmsg);
                return error.SQLiteCommitFailed;
            }
        }

        /// Aborts and rolls back the active transaction ("ROLLBACK").
        fn rollback(ctx: *anyopaque) anyerror!void {
            const self: *SQLiteTx = @ptrCast(@alignCast(ctx));
            defer self.allocator.destroy(self);
            var errmsg: [*c]u8 = null;
            if (c.sqlite3_exec(self.db, "ROLLBACK", null, null, &errmsg) != c.SQLITE_OK) {
                if (errmsg != null) c.sqlite3_free(errmsg);
                return error.SQLiteRollbackFailed;
            }
        }
    };
};

test "stdgo.database.sql.sqlite: in-memory CRUD and transaction rollback/commit" {
    if (!build_options.have_sqlite) return;

    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sq_driver = SQLiteDriver.init(testing.allocator);
    const sql_db = @import("../sql.zig");
    const db = try sql_db.DB.open(testing.allocator, io, sq_driver.driver(), ":memory:");
    defer db.close();

    try db.ping();

    // DDL
    _ = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, balance REAL)", &.{});

    // Insert
    const res1 = try db.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
        Value{ .string = "Alice" },
        Value{ .int = 30 },
        Value{ .float = 100.50 },
    });
    try testing.expectEqual(@as(i64, 1), res1.last_insert_id);
    try testing.expectEqual(@as(i64, 1), res1.rows_affected);

    const res2 = try db.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
        Value{ .string = "Bob" },
        Value{ .int = 25 },
        Value{ .float = 50.00 },
    });
    try testing.expectEqual(@as(i64, 2), res2.last_insert_id);
    try testing.expectEqual(@as(i64, 1), res2.rows_affected);

    // Query
    {
        var rows = try db.query("SELECT id, name, age, balance FROM users ORDER BY id ASC", &.{});
        defer rows.close();

        const cols = rows.columns();
        try testing.expectEqual(@as(usize, 4), cols.len);
        try testing.expectEqualStrings("id", cols[0]);
        try testing.expectEqualStrings("name", cols[1]);
        try testing.expectEqualStrings("age", cols[2]);
        try testing.expectEqualStrings("balance", cols[3]);

        var dest: [4]Value = undefined;

        // Row 1
        try testing.expect(rows.next(&dest));
        try testing.expectEqual(@as(i64, 1), dest[0].int);
        try testing.expectEqualStrings("Alice", dest[1].string);
        try testing.expectEqual(@as(i64, 30), dest[2].int);
        try testing.expectEqual(@as(f64, 100.50), dest[3].float);

        // Row 2
        try testing.expect(rows.next(&dest));
        try testing.expectEqual(@as(i64, 2), dest[0].int);
        try testing.expectEqualStrings("Bob", dest[1].string);
        try testing.expectEqual(@as(i64, 25), dest[2].int);
        try testing.expectEqual(@as(f64, 50.00), dest[3].float);

        // End of rows
        try testing.expect(!rows.next(&dest));
    }

    // Transaction Rollback
    {
        var tx = try db.begin();
        _ = try tx.exec("INSERT INTO users (name, age, balance) VALUES (?, ?, ?)", &.{
            Value{ .string = "Charlie" },
            Value{ .int = 40 },
            Value{ .float = 0.0 },
        });
        try tx.rollback();
    }

    // Verify Charlie was not inserted
    {
        var rows_after = try db.query("SELECT COUNT(*) FROM users WHERE name = ?", &.{
            Value{ .string = "Charlie" },
        });
        defer rows_after.close();
        var count_dest: [1]Value = undefined;
        try testing.expect(rows_after.next(&count_dest));
        try testing.expectEqual(@as(i64, 0), count_dest[0].int);
    }

    // Transaction Commit
    {
        var tx2 = try db.begin();
        _ = try tx2.exec("UPDATE users SET balance = balance + 10.0 WHERE name = ?", &.{
            Value{ .string = "Alice" },
        });
        try tx2.commit();
    }

    // Verify balance updated
    {
        var rows_alice = try db.query("SELECT balance FROM users WHERE name = ?", &.{
            Value{ .string = "Alice" },
        });
        defer rows_alice.close();
        var bal_dest: [1]Value = undefined;
        try testing.expect(rows_alice.next(&bal_dest));
        try testing.expectEqual(@as(f64, 110.50), bal_dest[0].float);
    }

    // Verify sqlite:// and sqlite3:// prefix handling
    {
        const url_db = try sql_db.DB.open(testing.allocator, io, sq_driver.driver(), "sqlite://:memory:");
        defer url_db.close();
        try url_db.ping();
    }
}

