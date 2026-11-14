//! Package database/sql provides a generic interface around SQL (or SQL-like) databases.
//!
//! It manages a thread-safe connection pool, connection life-cycle, transaction management,
//! and statement execution.

const std = @import("std");
const build_options = @import("build_options");
const driver_pkg = @import("sql/driver.zig");
pub const driver = driver_pkg;
pub const sqlite = if (build_options.have_sqlite) @import("sql/sqlite.zig") else struct {};
const Allocator = std.mem.Allocator;
const Mutex = @import("../sync/mutex.zig").Mutex;
const context = @import("../context.zig");

pub const Value = driver.Value;
pub const Result = driver.Result;

pub const DBStats = struct {
    max_open_connections: usize,
    open_connections: usize,
    in_use: usize,
    idle: usize,
    wait_count: u64,
    wait_duration_ns: u64,
    max_idle_closed: u64,
    max_lifetime_closed: u64,
};

/// Internal pooled connection tracked by DB.
pub const PooledConn = struct {
    raw: driver.Conn,
    created_at_ns: i128,
    last_used_at_ns: i128,
    db: *DB,

    pub fn release(self: *PooledConn) void {
        self.db.putConn(self);
    }

    /// Interrupt aborts any in-progress query on this connection out-of-band.
    /// Returns true if supported and signaled, false otherwise.
    pub fn interrupt(self: *PooledConn) bool {
        return self.raw.interrupt();
    }

    /// Exec executes a query on this specific connection.
    pub fn exec(self: *PooledConn, query_str: []const u8, args: []const Value) !Result {
        var stmt = try self.raw.prepare(query_str);
        defer stmt.close();
        return try stmt.exec(args);
    }

    /// Query executes a query on this specific connection.
    pub fn query(self: *PooledConn, query_str: []const u8, args: []const Value) !Rows {
        var stmt = try self.raw.prepare(query_str);
        errdefer stmt.close();
        const raw_rows = try stmt.query(args);
        return Rows{
            .pooled_conn = null,
            .stmt = stmt,
            .raw_rows = raw_rows,
        };
    }

    /// ExecContext executes a query on this connection observing ctx for cancellation.
    pub fn execContext(self: *PooledConn, ctx: context.Context, query_str: []const u8, args: []const Value) !Result {
        if (ctx.err()) |e| return e;

        var done_flag = std.atomic.Value(bool).init(false);
        const Watchdog = struct {
            fn run(flag_ptr: *std.atomic.Value(bool), pc_ptr: *PooledConn, c_ctx: context.Context, c_io: std.Io) void {
                while (!flag_ptr.load(.acquire)) {
                    if (c_ctx.err() != null) {
                        _ = pc_ptr.interrupt();
                        break;
                    }
                    c_io.sleep(std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
                }
            }
        };

        const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{ &done_flag, self, ctx, self.db.io }) catch null;
        defer {
            done_flag.store(true, .release);
            if (watchdog_thread) |wt| wt.join();
        }

        var stmt = try self.raw.prepare(query_str);
        defer stmt.close();

        const res = stmt.exec(args) catch |err| {
            if (ctx.err()) |ce| return ce;
            return err;
        };
        if (ctx.err()) |ce| return ce;
        return res;
    }

    /// QueryContext executes a query returning rows on this connection observing ctx for cancellation.
    pub fn queryContext(self: *PooledConn, ctx: context.Context, query_str: []const u8, args: []const Value) !Rows {
        if (ctx.err()) |e| return e;

        var done_flag = std.atomic.Value(bool).init(false);
        const Watchdog = struct {
            fn run(flag_ptr: *std.atomic.Value(bool), pc_ptr: *PooledConn, c_ctx: context.Context, c_io: std.Io) void {
                while (!flag_ptr.load(.acquire)) {
                    if (c_ctx.err() != null) {
                        _ = pc_ptr.interrupt();
                        break;
                    }
                    c_io.sleep(std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
                }
            }
        };

        const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{ &done_flag, self, ctx, self.db.io }) catch null;
        defer {
            done_flag.store(true, .release);
            if (watchdog_thread) |wt| wt.join();
        }

        var stmt = try self.raw.prepare(query_str);
        errdefer stmt.close();

        const raw_rows = stmt.query(args) catch |err| {
            if (ctx.err()) |ce| return ce;
            return err;
        };
        if (ctx.err()) |ce| {
            var r = raw_rows;
            r.close();
            return ce;
        }

        return Rows{
            .pooled_conn = null,
            .stmt = stmt,
            .raw_rows = raw_rows,
        };
    }
};

/// DB is a database handle representing a pool of zero or more underlying connections.
/// It is safe for concurrent use by multiple threads.
pub const DB = struct {
    allocator: Allocator,
    io: std.Io,
    driver_instance: driver.Driver,
    dsn: []const u8,

    mutex: Mutex = .{},

    max_open_conns: usize = 0, // 0 means unlimited
    max_idle_conns: usize = 2,
    conn_max_lifetime_ns: ?u64 = null,

    num_open: usize = 0,
    free_conns: std.ArrayList(*PooledConn),
    active_conns: std.ArrayList(*PooledConn),
    closed: bool = false,

    wait_count: u64 = 0,
    wait_duration_ns: u64 = 0,
    max_idle_closed: u64 = 0,
    max_lifetime_closed: u64 = 0,

    /// Open opens a database specified by its database driver and DSN, explicitly
    /// taking std.Io for clock and timeout tracking.
    pub fn open(allocator: Allocator, io: std.Io, drv: driver.Driver, dsn: []const u8) !*DB {
        const db = try allocator.create(DB);
        const dsn_copy = try allocator.dupe(u8, dsn);
        db.* = .{
            .allocator = allocator,
            .io = io,
            .driver_instance = drv,
            .dsn = dsn_copy,
            .free_conns = std.ArrayList(*PooledConn).empty,
            .active_conns = std.ArrayList(*PooledConn).empty,
        };
        return db;
    }

    fn currentNanoTimestamp(self: *DB) i128 {
        return @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
    }

    /// Close closes the database and prevents new queries from starting.
    /// Close then waits for all queries that have started processing on the server
    /// to finish and closes all idle connections.
    pub fn close(self: *DB) void {
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        self.closed = true;

        for (self.free_conns.items) |pc| {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
        }
        self.free_conns.deinit(self.allocator);

        for (self.active_conns.items) |pc| {
            _ = pc.interrupt();
        }
        self.active_conns.deinit(self.allocator);
        self.mutex.unlock();

        self.allocator.free(self.dsn);
        self.allocator.destroy(self);
    }

    /// SetMaxOpenConns sets the maximum number of open connections to the database.
    /// If n <= 0, then there is no limit on the number of open connections.
    pub fn setMaxOpenConns(self: *DB, n: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.max_open_conns = n;
    }

    /// SetMaxIdleConns sets the maximum number of connections in the idle
    /// connection pool.
    pub fn setMaxIdleConns(self: *DB, n: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.max_idle_conns = n;
        while (self.free_conns.items.len > self.max_idle_conns) {
            const pc = self.free_conns.pop().?;
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.max_idle_closed += 1;
        }
    }

    /// SetConnMaxLifetime sets the maximum amount of time a connection may be reused.
    pub fn setConnMaxLifetime(self: *DB, duration_ns: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.conn_max_lifetime_ns = duration_ns;
    }

    /// Stats returns database statistics.
    pub fn stats(self: *DB) DBStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idle = self.free_conns.items.len;
        return .{
            .max_open_connections = self.max_open_conns,
            .open_connections = self.num_open,
            .in_use = self.num_open - idle,
            .idle = idle,
            .wait_count = self.wait_count,
            .wait_duration_ns = self.wait_duration_ns,
            .max_idle_closed = self.max_idle_closed,
            .max_lifetime_closed = self.max_lifetime_closed,
        };
    }

    /// Ping verifies a connection to the database is still alive, establishing a connection if necessary.
    pub fn ping(self: *DB) !void {
        const pc = try self.conn();
        defer pc.release();
        try pc.raw.ping();
    }

    /// conn returns a single connection by either opening a new connection
    /// or returning an existing connection from the free pool.
    pub fn conn(self: *DB) !*PooledConn {
        const start_wait = self.currentNanoTimestamp();
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.closed) return error.DBClosed;

            const now = self.currentNanoTimestamp();

            // 1. Try to find a valid idle connection
            while (self.free_conns.items.len > 0) {
                const pc = self.free_conns.pop().?;
                if (self.conn_max_lifetime_ns) |max_life| {
                    if (now - pc.created_at_ns > max_life) {
                        pc.raw.close();
                        self.allocator.destroy(pc);
                        self.num_open -= 1;
                        self.max_lifetime_closed += 1;
                        continue;
                    }
                }
                pc.last_used_at_ns = now;
                self.active_conns.append(self.allocator, pc) catch {};
                return pc;
            }

            // 2. Open a new connection if under max_open_conns
            if (self.max_open_conns == 0 or self.num_open < self.max_open_conns) {
                self.num_open += 1;
                // Temporarily release mutex while opening connection to avoid blocking other threads
                self.mutex.unlock();
                const raw_conn = self.driver_instance.open(self.dsn) catch |err| {
                    self.mutex.lock();
                    self.num_open -= 1;
                    return err;
                };
                self.mutex.lock();

                const pc = try self.allocator.create(PooledConn);
                pc.* = .{
                    .raw = raw_conn,
                    .created_at_ns = self.currentNanoTimestamp(),
                    .last_used_at_ns = self.currentNanoTimestamp(),
                    .db = self,
                };
                self.active_conns.append(self.allocator, pc) catch {};
                return pc;
            }

            // 3. Pool is exhausted; yield and retry
            self.wait_count += 1;
            self.mutex.unlock();
            std.Thread.yield() catch {};
            self.mutex.lock();
            const waited = self.currentNanoTimestamp() - start_wait;
            if (waited > 0) {
                self.wait_duration_ns += @intCast(waited);
            }
        }
    }

    pub fn putConn(self: *DB, pc: *PooledConn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.active_conns.items, 0..) |item, i| {
            if (item == pc) {
                _ = self.active_conns.swapRemove(i);
                break;
            }
        }

        if (self.closed) {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            return;
        }

        const now = self.currentNanoTimestamp();
        if (self.conn_max_lifetime_ns) |max_life| {
            if (now - pc.created_at_ns > max_life) {
                pc.raw.close();
                self.allocator.destroy(pc);
                self.num_open -= 1;
                self.max_lifetime_closed += 1;
                return;
            }
        }

        if (self.free_conns.items.len >= self.max_idle_conns) {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            self.max_idle_closed += 1;
            return;
        }

        pc.last_used_at_ns = now;
        self.free_conns.append(self.allocator, pc) catch {
            pc.raw.close();
            self.allocator.destroy(pc);
            self.num_open -= 1;
            return;
        };
    }

    /// Exec executes a query without returning any rows.
    pub fn exec(self: *DB, query_str: []const u8, args: []const Value) !Result {
        const pc = try self.conn();
        defer pc.release();

        var stmt = try pc.raw.prepare(query_str);
        defer stmt.close();
        return try stmt.exec(args);
    }

    /// Query executes a query that returns rows, typically a SELECT.
    pub fn query(self: *DB, query_str: []const u8, args: []const Value) !Rows {
        const pc = try self.conn();
        errdefer pc.release();

        var stmt = try pc.raw.prepare(query_str);
        errdefer stmt.close();

        const raw_rows = try stmt.query(args);
        return Rows{
            .pooled_conn = pc,
            .stmt = stmt,
            .raw_rows = raw_rows,
        };
    }

    /// InterruptAll signals all currently active/in-flight queries across the pool to abort out-of-band.
    /// Returns the number of connections that were successfully signaled.
    pub fn interruptAll(self: *DB) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.active_conns.items) |pc| {
            if (pc.interrupt()) {
                count += 1;
            }
        }
        return count;
    }

    /// ExecContext executes a query without returning any rows, observing the context for cancellation.
    pub fn execContext(self: *DB, ctx: context.Context, query_str: []const u8, args: []const Value) !Result {
        if (ctx.err()) |e| return e;
        const pc = try self.conn();
        defer pc.release();
        return try pc.execContext(ctx, query_str, args);
    }

    /// QueryContext executes a query that returns rows, observing the context for cancellation.
    pub fn queryContext(self: *DB, ctx: context.Context, query_str: []const u8, args: []const Value) !Rows {
        if (ctx.err()) |e| return e;
        const pc = try self.conn();
        errdefer pc.release();
        var rows = try pc.queryContext(ctx, query_str, args);
        rows.pooled_conn = pc;
        return rows;
    }

    /// Begin starts a transaction.
    pub fn begin(self: *DB) !Tx {
        const pc = try self.conn();
        errdefer pc.release();

        const raw_tx = try pc.raw.begin();
        return Tx{
            .pooled_conn = pc,
            .raw_tx = raw_tx,
        };
    }
};

/// Rows is the result of a query. Its cursor starts before the first row of the result set.
/// Use Next to advance through the rows.
pub const Rows = struct {
    pooled_conn: ?*PooledConn,
    stmt: driver.Stmt,
    raw_rows: driver.Rows,
    closed: bool = false,

    pub fn columns(self: *Rows) []const []const u8 {
        return self.raw_rows.columns();
    }

    pub fn next(self: *Rows, dest: []Value) bool {
        if (self.closed) return false;
        const has_more = self.raw_rows.next(dest);
        if (!has_more) {
            self.close();
        }
        return has_more;
    }

    pub fn close(self: *Rows) void {
        if (self.closed) return;
        self.closed = true;
        self.raw_rows.close();
        self.stmt.close();
        if (self.pooled_conn) |pc| {
            pc.release();
            self.pooled_conn = null;
        }
    }
};

/// Tx is an in-progress database transaction.
///
/// A transaction must end with a call to Commit or Rollback, which releases
/// the underlying pooled connection back to the DB pool.
pub const Tx = struct {
    pooled_conn: ?*PooledConn,
    raw_tx: driver.Tx,
    done: bool = false,

    /// Commits the transaction and returns the connection to the pool.
    pub fn commit(self: *Tx) !void {
        if (self.done) return error.TxDone;
        self.done = true;
        defer {
            if (self.pooled_conn) |pc| {
                pc.release();
                self.pooled_conn = null;
            }
        }
        try self.raw_tx.commit();
    }

    /// Aborts and rolls back the transaction, returning the connection to the pool.
    pub fn rollback(self: *Tx) !void {
        if (self.done) return error.TxDone;
        self.done = true;
        defer {
            if (self.pooled_conn) |pc| {
                pc.release();
                self.pooled_conn = null;
            }
        }
        try self.raw_tx.rollback();
    }

    /// Executes a query within the transaction that does not return rows (e.g. INSERT, UPDATE).
    pub fn exec(self: *Tx, query_str: []const u8, args: []const Value) !Result {
        if (self.done) return error.TxDone;
        const pc = self.pooled_conn orelse return error.TxDone;
        var stmt = try pc.raw.prepare(query_str);
        defer stmt.close();
        return try stmt.exec(args);
    }

    /// Executes a query within the transaction that returns rows (e.g. SELECT).
    /// The transaction connection remains tied to this transaction until commit or rollback.
    pub fn query(self: *Tx, query_str: []const u8, args: []const Value) !Rows {
        if (self.done) return error.TxDone;
        const pc = self.pooled_conn orelse return error.TxDone;
        var stmt = try pc.raw.prepare(query_str);
        errdefer stmt.close();
        const raw_rows = try stmt.query(args);
        return Rows{
            .pooled_conn = null, // tx retains connection until commit/rollback
            .stmt = stmt,
            .raw_rows = raw_rows,
        };
    }
};

// -------------------------------------------------------------------------
// Built-in In-Memory Mock Driver for Unit Testing & Demonstration
// -------------------------------------------------------------------------

pub const MockDriver = struct {
    pub const RowData = struct {
        cols: []const []const u8,
        data: []const Value,
    };

    pub const State = struct {
        allocator: Allocator,
        mutex: Mutex = .{},
        open_count: usize = 0,
        close_count: usize = 0,
        interrupt_count: usize = 0,
        executed_queries: std.ArrayList([]const u8),
        tx_commits: usize = 0,
        tx_rollbacks: usize = 0,

        pub fn init(allocator: Allocator) State {
            return .{
                .allocator = allocator,
                .executed_queries = std.ArrayList([]const u8).empty,
            };
        }

        pub fn deinit(self: *State) void {
            for (self.executed_queries.items) |q| self.allocator.free(q);
            self.executed_queries.deinit(self.allocator);
        }
    };

    state: *State,

    pub fn driver(self: *MockDriver) driver_pkg.Driver {
        return .{
            .ptr = self,
            .vtable = &.{
                .open = MockDriver.open,
            },
        };
    }

    fn open(ctx: *anyopaque, _: []const u8) anyerror!driver_pkg.Conn {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        {
            self.state.mutex.lock();
            defer self.state.mutex.unlock();
            self.state.open_count += 1;
        }

        const conn_ctx = try self.state.allocator.create(MockConn);
        conn_ctx.* = .{
            .driver = self,
            .state = self.state,
        };

        return driver_pkg.Conn{
            .ptr = conn_ctx,
            .vtable = &.{
                .prepare = MockConn.prepare,
                .close = MockConn.close,
                .begin = MockConn.begin,
                .ping = MockConn.ping,
                .interrupt = MockConn.interrupt,
            },
        };
    }

    const MockConn = struct {
        driver: *MockDriver,
        state: *State,

        fn prepare(ctx: *anyopaque, query_str: []const u8) anyerror!driver_pkg.Stmt {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            const q_copy = try self.state.allocator.dupe(u8, query_str);
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                try self.state.executed_queries.append(self.state.allocator, q_copy);
            }

            const stmt_ctx = try self.state.allocator.create(MockStmt);
            stmt_ctx.* = .{ .conn = self };
            return driver_pkg.Stmt{
                .ptr = stmt_ctx,
                .vtable = &.{
                    .close = MockStmt.close,
                    .numInput = MockStmt.numInput,
                    .exec = MockStmt.exec,
                    .query = MockStmt.query,
                },
            };
        }

        fn close(ctx: *anyopaque) void {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            {
                self.state.mutex.lock();
                defer self.state.mutex.unlock();
                self.state.close_count += 1;
            }
            self.state.allocator.destroy(self);
        }

        fn begin(ctx: *anyopaque) anyerror!driver_pkg.Tx {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            const tx_ctx = try self.state.allocator.create(MockTx);
            tx_ctx.* = .{ .conn = self };
            return driver_pkg.Tx{
                .ptr = tx_ctx,
                .vtable = &.{
                    .commit = MockTx.commit,
                    .rollback = MockTx.rollback,
                },
            };
        }

        fn ping(_: *anyopaque) anyerror!void {}

        fn interrupt(ctx: *anyopaque) void {
            const self: *MockConn = @ptrCast(@alignCast(ctx));
            self.state.mutex.lock();
            defer self.state.mutex.unlock();
            self.state.interrupt_count += 1;
        }
    };

    const MockStmt = struct {
        conn: *MockConn,

        fn close(ctx: *anyopaque) void {
            const self: *MockStmt = @ptrCast(@alignCast(ctx));
            self.conn.state.allocator.destroy(self);
        }

        fn numInput(_: *anyopaque) i64 {
            return 0;
        }

        fn exec(_: *anyopaque, _: []const Value) anyerror!Result {
            return Result{
                .last_insert_id = 1001,
                .rows_affected = 1,
            };
        }

        fn query(ctx: *anyopaque, _: []const Value) anyerror!driver_pkg.Rows {
            const self: *MockStmt = @ptrCast(@alignCast(ctx));
            const rows_ctx = try self.conn.state.allocator.create(MockRows);
            rows_ctx.* = .{
                .conn = self.conn,
                .cursor = 0,
            };
            return driver_pkg.Rows{
                .ptr = rows_ctx,
                .vtable = &.{
                    .columns = MockRows.columns,
                    .next = MockRows.next,
                    .close = MockRows.close,
                },
            };
        }
    };

    const MockRows = struct {
        conn: *MockConn,
        cursor: usize = 0,

        const cols = [_][]const u8{ "id", "name", "role" };

        fn columns(_: *anyopaque) []const []const u8 {
            return &cols;
        }

        fn next(ctx: *anyopaque, dest: []Value) bool {
            const self: *MockRows = @ptrCast(@alignCast(ctx));
            if (self.cursor >= 2) return false;

            if (self.cursor == 0) {
                dest[0] = Value{ .int = 1 };
                dest[1] = Value{ .string = "alice" };
                dest[2] = Value{ .string = "admin" };
            } else if (self.cursor == 1) {
                dest[0] = Value{ .int = 2 };
                dest[1] = Value{ .string = "bob" };
                dest[2] = Value{ .string = "dev" };
            }
            self.cursor += 1;
            return true;
        }

        fn close(ctx: *anyopaque) void {
            const self: *MockRows = @ptrCast(@alignCast(ctx));
            self.conn.state.allocator.destroy(self);
        }
    };

    const MockTx = struct {
        conn: *MockConn,

        fn commit(ctx: *anyopaque) anyerror!void {
            const self: *MockTx = @ptrCast(@alignCast(ctx));
            self.conn.state.tx_commits += 1;
            self.conn.state.allocator.destroy(self);
        }

        fn rollback(ctx: *anyopaque) anyerror!void {
            const self: *MockTx = @ptrCast(@alignCast(ctx));
            self.conn.state.tx_rollbacks += 1;
            self.conn.state.allocator.destroy(self);
        }
    };
};

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "database.sql: basic open, ping, exec, query and close" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Ping
    try db.ping();
    var s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.open_connections);
    try testing.expectEqual(@as(usize, 1), s.idle);

    // 2. Exec
    const res = try db.exec("INSERT INTO users (name) VALUES (?)", &.{Value{ .string = "charlie" }});
    try testing.expectEqual(@as(i64, 1001), res.lastInsertId());
    try testing.expectEqual(@as(i64, 1), res.rowsAffected());

    // 3. Query
    var rows = try db.query("SELECT id, name, role FROM users", &.{});
    defer rows.close();

    const cols = rows.columns();
    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("id", cols[0]);

    var record: [3]Value = undefined;
    var count: usize = 0;
    while (rows.next(&record)) {
        count += 1;
        if (count == 1) {
            try testing.expectEqual(@as(i64, 1), record[0].int);
            try testing.expectEqualStrings("alice", record[1].string);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);

    // After rows closed, connection is returned to pool
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
}

test "database.sql: transaction commit and rollback" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Commit
    {
        var tx = try db.begin();
        _ = try tx.exec("UPDATE accounts SET balance = balance - 100", &.{});
        try tx.commit();
        try testing.expectEqual(@as(usize, 1), state.tx_commits);
        // Error on repeated commit
        try testing.expectError(error.TxDone, tx.commit());
    }

    // 2. Rollback
    {
        var tx = try db.begin();
        _ = try tx.exec("DELETE FROM logs", &.{});
        try tx.rollback();
        try testing.expectEqual(@as(usize, 1), state.tx_rollbacks);
        try testing.expectError(error.TxDone, tx.rollback());
    }
}

test "database.sql: max open and idle connections pool limit" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    db.setMaxOpenConns(2);
    db.setMaxIdleConns(1);

    // Acquire 2 connections
    const c1 = try db.conn();
    const c2 = try db.conn();

    var s = db.stats();
    try testing.expectEqual(@as(usize, 2), s.open_connections);
    try testing.expectEqual(@as(usize, 2), s.in_use);
    try testing.expectEqual(@as(usize, 0), s.idle);

    // Release c1 -> goes to idle
    c1.release();
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 1), s.in_use);

    // Release c2 -> max_idle is 1, so c2 is closed!
    c2.release();
    s = db.stats();
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 1), s.open_connections);
    try testing.expectEqual(@as(u64, 1), s.max_idle_closed);
}

test "database.sql: concurrent connection pool contention" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // Strict limit: only 2 simultaneous connections allowed
    db.setMaxOpenConns(2);
    db.setMaxIdleConns(2);

    const Worker = struct {
        fn run(db_ptr: *DB) void {
            for (0..20) |_| {
                const pc = db_ptr.conn() catch return;
                defer pc.release();
                // Simulating query execution
                var stmt = pc.raw.prepare("SELECT 1") catch continue;
                defer stmt.close();
                _ = stmt.exec(&.{}) catch {};
            }
        }
    };

    // Spawn 4 concurrent threads fighting for 2 connections
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{db});
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{db});
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{db});
    const t4 = try std.Thread.spawn(.{}, Worker.run, .{db});

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    const s = db.stats();
    // After all finished, open connections <= 2 and in_use == 0
    try testing.expect(s.open_connections <= 2);
    try testing.expectEqual(@as(usize, 0), s.in_use);
    try testing.expect(state.executed_queries.items.len >= 60);
}

test "database.sql: interrupt and context cancellation" {
    const testing = std.testing;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = MockDriver.State.init(testing.allocator);
    defer state.deinit();

    var mock = MockDriver{ .state = &state };
    const db = try DB.open(testing.allocator, io, mock.driver(), "mock://localhost/testdb");
    defer db.close();

    // 1. Single connection interrupt()
    {
        const pc = try db.conn();
        defer pc.release();

        try testing.expect(pc.interrupt());
        try testing.expectEqual(@as(usize, 1), state.interrupt_count);
    }

    // 2. DB.interruptAll() across active pool connections
    {
        const pc1 = try db.conn();
        defer pc1.release();
        const pc2 = try db.conn();
        defer pc2.release();

        const interrupted_count = db.interruptAll();
        try testing.expectEqual(@as(usize, 2), interrupted_count);
        try testing.expectEqual(@as(usize, 3), state.interrupt_count);
    }

    // 3. ExecContext / QueryContext with canceled Context
    {
        var cancel_node = try context.withCancel(testing.allocator, context.background());
        defer testing.allocator.destroy(cancel_node);
        cancel_node.cancel();

        try testing.expectError(context.Error.Canceled, db.execContext(cancel_node.context(), "SELECT 1", &.{}));
        try testing.expectError(context.Error.Canceled, db.queryContext(cancel_node.context(), "SELECT 1", &.{}));
    }
}

test {
    if (build_options.have_sqlite) {
        _ = sqlite;
    }
}

