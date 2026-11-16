//! HTTP Keep-Alive connection pool keyed by host:port:is_tls.
const std = @import("std");
const HttpConn = @import("conn.zig").HttpConn;
const Mutex = @import("../../sync/mutex.zig").Mutex;

pub const PooledConn = struct {
    host: []const u8,
    port: u16,
    is_tls: bool,
    conn: *HttpConn,
};

pub const ConnPool = struct {
    allocator: std.mem.Allocator,
    max_idle_per_host: usize,
    entries: std.ArrayListUnmanaged(PooledConn),
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, max_idle_per_host: usize) ConnPool {
        return .{
            .allocator = allocator,
            .max_idle_per_host = max_idle_per_host,
            .entries = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnPool, io: std.Io) void {
        self.mutex.lock();
        const to_close = self.entries.toOwnedSlice(self.allocator) catch {
            for (self.entries.items) |entry| {
                entry.conn.close(io);
                self.allocator.destroy(entry.conn);
                self.allocator.free(entry.host);
            }
            self.entries.deinit(self.allocator);
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (to_close) |entry| {
            entry.conn.close(io);
            self.allocator.destroy(entry.conn);
            self.allocator.free(entry.host);
        }
        self.allocator.free(to_close);
    }

    pub fn acquire(self: *ConnPool, host: []const u8, port: u16, is_tls: bool) ?*HttpConn {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            if (entry.port == port and entry.is_tls == is_tls and std.mem.eql(u8, entry.host, host)) {
                const conn = entry.conn;
                self.allocator.free(entry.host);
                _ = self.entries.swapRemove(i);
                return conn;
            }
        }
        return null;
    }

    pub fn release(self: *ConnPool, io: std.Io, host: []const u8, port: u16, is_tls: bool, conn: *HttpConn) void {
        self.mutex.lock();
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.port == port and entry.is_tls == is_tls and std.mem.eql(u8, entry.host, host)) {
                count += 1;
            }
        }

        if (count >= self.max_idle_per_host) {
            self.mutex.unlock();
            conn.close(io);
            self.allocator.destroy(conn);
            return;
        }

        const owned_host = self.allocator.dupe(u8, host) catch {
            self.mutex.unlock();
            conn.close(io);
            self.allocator.destroy(conn);
            return;
        };

        self.entries.append(self.allocator, .{
            .host = owned_host,
            .port = port,
            .is_tls = is_tls,
            .conn = conn,
        }) catch {
            self.mutex.unlock();
            self.allocator.free(owned_host);
            conn.close(io);
            self.allocator.destroy(conn);
            return;
        };
        self.mutex.unlock();
    }

    /// closeIdleConnections closes and drains all idle connections currently in the pool.
    pub fn closeIdleConnections(self: *ConnPool, io: std.Io) void {
        self.mutex.lock();
        const to_close = self.entries.toOwnedSlice(self.allocator) catch {
            for (self.entries.items) |entry| {
                entry.conn.close(io);
                self.allocator.destroy(entry.conn);
                self.allocator.free(entry.host);
            }
            self.entries.clearRetainingCapacity();
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (to_close) |entry| {
            entry.conn.close(io);
            self.allocator.destroy(entry.conn);
            self.allocator.free(entry.host);
        }
        self.allocator.free(to_close);
    }
};
