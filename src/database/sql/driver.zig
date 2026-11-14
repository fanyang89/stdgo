//! Package database/sql/driver defines interfaces to be implemented by database drivers
//! as required by package database/sql.

const std = @import("std");

/// Driver value representation.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("NULL"),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .string => |s| try writer.print("'{s}'", .{s}),
            .bytes => |b| try writer.print("0x{s}", .{std.fmt.fmtSliceHexLower(b)}),
        }
    }
};

/// Result of an Exec query (e.g. INSERT, UPDATE, DELETE).
pub const Result = struct {
    last_insert_id: i64 = 0,
    rows_affected: i64 = 0,

    pub fn lastInsertId(self: Result) i64 {
        return self.last_insert_id;
    }

    pub fn rowsAffected(self: Result) i64 {
        return self.rows_affected;
    }
};

/// Rows is an iterator over an executed query's results.
pub const Rows = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        columns: *const fn (ctx: *anyopaque) []const []const u8,
        next: *const fn (ctx: *anyopaque, dest: []Value) bool,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn columns(self: *Rows) []const []const u8 {
        return self.vtable.columns(self.ptr);
    }

    pub fn next(self: *Rows, dest: []Value) bool {
        return self.vtable.next(self.ptr, dest);
    }

    pub fn close(self: *Rows) void {
        self.vtable.close(self.ptr);
    }
};

/// Stmt is a prepared statement bound to a Conn.
pub const Stmt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (ctx: *anyopaque) void,
        numInput: *const fn (ctx: *anyopaque) i64,
        exec: *const fn (ctx: *anyopaque, args: []const Value) anyerror!Result,
        query: *const fn (ctx: *anyopaque, args: []const Value) anyerror!Rows,
    };

    pub fn close(self: *Stmt) void {
        self.vtable.close(self.ptr);
    }

    pub fn numInput(self: *Stmt) i64 {
        return self.vtable.numInput(self.ptr);
    }

    pub fn exec(self: *Stmt, args: []const Value) !Result {
        return self.vtable.exec(self.ptr, args);
    }

    pub fn query(self: *Stmt, args: []const Value) !Rows {
        return self.vtable.query(self.ptr, args);
    }
};

/// Tx is an in-progress transaction on a Conn.
pub const Tx = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        commit: *const fn (ctx: *anyopaque) anyerror!void,
        rollback: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn commit(self: *Tx) !void {
        return self.vtable.commit(self.ptr);
    }

    pub fn rollback(self: *Tx) !void {
        return self.vtable.rollback(self.ptr);
    }
};

/// Conn is a connection to a database. It is not used concurrently by multiple threads.
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prepare: *const fn (ctx: *anyopaque, query: []const u8) anyerror!Stmt,
        close: *const fn (ctx: *anyopaque) void,
        begin: *const fn (ctx: *anyopaque) anyerror!Tx,
        ping: *const fn (ctx: *anyopaque) anyerror!void,
        /// [Extension to standard Go driver.Conn]
        /// Optional: Interrupts any in-progress query on this connection (e.g. sqlite3_interrupt,
        /// PostgreSQL CancelRequest, MySQL KILL QUERY).
        /// This extension allows GUI clients (such as Qianliyan) and Context cancellation to
        /// abort slow queries out-of-band without destroying the underlying connection or pool.
        interrupt: ?*const fn (ctx: *anyopaque) void = null,
    };

    pub fn prepare(self: *Conn, query: []const u8) !Stmt {
        return self.vtable.prepare(self.ptr, query);
    }

    pub fn close(self: *Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn begin(self: *Conn) !Tx {
        return self.vtable.begin(self.ptr);
    }

    pub fn ping(self: *Conn) !void {
        return self.vtable.ping(self.ptr);
    }

    /// Interrupt aborts any in-progress database operation on this connection out-of-band.
    /// Returns true if the underlying driver supports interruption and the signal was sent,
    /// or false if unsupported by this driver.
    pub fn interrupt(self: *Conn) bool {
        if (self.vtable.interrupt) |f| {
            f(self.ptr);
            return true;
        }
        return false;
    }
};

/// Driver is the interface that must be implemented by a database driver.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, dsn: []const u8) anyerror!Conn,
    };

    pub fn open(self: Driver, dsn: []const u8) !Conn {
        return self.vtable.open(self.ptr, dsn);
    }
};
