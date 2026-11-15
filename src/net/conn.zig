//! Generic network connection abstraction conforming to Go's net.Conn, net.Listener, and net.Dialer interfaces.
const std = @import("std");
const io_mod = @import("../io.zig");
const context = @import("../context.zig");
const Context = context.Context;
const time_mod = @import("../time.zig");
const Duration = time_mod.Duration;
const Time = time_mod.Time;
const hostport = @import("hostport.zig");

/// Conn represents a generic stream-oriented network connection,
/// equivalent to Go's net.Conn interface.
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
        localAddr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
        remoteAddr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    };

    pub fn read(self: Conn, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn write(self: Conn, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn close(self: Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn localAddr(self: Conn) ?[]const u8 {
        if (self.vtable.localAddr) |f| return f(self.ptr);
        return null;
    }

    pub fn remoteAddr(self: Conn) ?[]const u8 {
        if (self.vtable.remoteAddr) |f| return f(self.ptr);
        return null;
    }
};

/// Listener represents a generic stream listener, equivalent to Go's net.Listener interface.
pub const Listener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (ctx: *anyopaque) anyerror!Conn,
        close: *const fn (ctx: *anyopaque) void,
        addr: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
        port: ?*const fn (ctx: *anyopaque) u16 = null,
    };

    pub fn accept(self: Listener) anyerror!Conn {
        return self.vtable.accept(self.ptr);
    }

    pub fn close(self: Listener) void {
        self.vtable.close(self.ptr);
    }

    pub fn addr(self: Listener) ?[]const u8 {
        if (self.vtable.addr) |f| return f(self.ptr);
        return null;
    }

    pub fn port(self: Listener) ?u16 {
        if (self.vtable.port) |f| return f(self.ptr);
        return null;
    }
};

/// StreamConn is a concrete implementation of net.Conn backed by std.Io.net.Stream.
pub const StreamConn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buf: [4096]u8 = undefined,
    reader_inst: std.Io.net.Stream.Reader = undefined,
    write_buf: [4096]u8 = undefined,
    writer_inst: std.Io.net.Stream.Writer = undefined,
    remote_addr_buf: [64]u8 = undefined,
    remote_addr_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io_inst: std.Io, stream: std.Io.net.Stream, remote_addr_str: ?[]const u8) !*StreamConn {
        const sc = try allocator.create(StreamConn);
        sc.* = .{
            .allocator = allocator,
            .io = io_inst,
            .stream = stream,
        };
        sc.reader_inst = stream.reader(io_inst, &sc.read_buf);
        sc.writer_inst = stream.writer(io_inst, &sc.write_buf);

        if (remote_addr_str) |s| {
            const copy_len = @min(s.len, sc.remote_addr_buf.len);
            @memcpy(sc.remote_addr_buf[0..copy_len], s[0..copy_len]);
            sc.remote_addr_len = copy_len;
        }

        return sc;
    }

    pub fn conn(self: *StreamConn) Conn {
        return .{
            .ptr = self,
            .vtable = &stream_conn_vtable,
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        const r = &self.reader_inst.interface;
        if (r.buffered().len == 0) {
            r.fillMore() catch |err| {
                if (err == error.EndOfStream) return 0;
                return err;
            };
        }
        const avail = r.buffered();
        if (avail.len == 0) return 0;
        const n = @min(avail.len, buf.len);
        @memcpy(buf[0..n], avail[0..n]);
        r.toss(n);
        return n;
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        const w = &self.writer_inst.interface;
        try w.writeAll(bytes);
        try w.flush();
        return bytes.len;
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn remoteAddrImpl(ctx: *anyopaque) ?[]const u8 {
        const self: *StreamConn = @ptrCast(@alignCast(ctx));
        if (self.remote_addr_len > 0) {
            return self.remote_addr_buf[0..self.remote_addr_len];
        }
        return null;
    }

    const stream_conn_vtable: Conn.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .close = closeImpl,
        .remoteAddr = remoteAddrImpl,
    };
};

/// TCPListener is a concrete implementation of net.Listener backed by std.Io.net.Server.
pub const TCPListener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    addr_buf: [64]u8 = undefined,
    addr_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, server: std.Io.net.Server) !*TCPListener {
        const self = try allocator.create(TCPListener);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
        };
        const p = self.port();
        const formatted = std.fmt.bufPrint(&self.addr_buf, "127.0.0.1:{d}", .{p}) catch "";
        self.addr_len = formatted.len;
        return self;
    }

    pub fn port(self: *const TCPListener) u16 {
        return self.server.socket.address.ip4.port;
    }

    pub fn listener(self: *TCPListener) Listener {
        return .{
            .ptr = self,
            .vtable = &tcp_listener_vtable,
        };
    }

    fn acceptImpl(ctx: *anyopaque) anyerror!Conn {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        const stream = try self.server.accept(self.io);
        errdefer stream.close(self.io);

        const sc = try StreamConn.init(self.allocator, self.io, stream, null);
        return sc.conn();
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        self.server.deinit(self.io);
        self.allocator.destroy(self);
    }

    fn addrImpl(ctx: *anyopaque) ?[]const u8 {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        if (self.addr_len > 0) return self.addr_buf[0..self.addr_len];
        return null;
    }

    fn portImpl(ctx: *anyopaque) u16 {
        const self: *TCPListener = @ptrCast(@alignCast(ctx));
        return self.port();
    }

    const tcp_listener_vtable: Listener.VTable = .{
        .accept = acceptImpl,
        .close = closeImpl,
        .addr = addrImpl,
        .port = portImpl,
    };
};

/// Listen announces on the local network address.
pub fn listen(allocator: std.mem.Allocator, io: std.Io, network: []const u8, address: []const u8) !Listener {
    if (!std.mem.startsWith(u8, network, "tcp")) {
        return error.UnknownNetwork;
    }

    const hp = try hostport.splitHostPort(address);
    const port = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;
    const bind_host = if (hp.host.len == 0 or std.mem.eql(u8, hp.host, "0.0.0.0")) "0.0.0.0" else hp.host;

    const bind_ip = try std.Io.net.IpAddress.parse(bind_host, port);
    const server = try bind_ip.listen(io, .{ .reuse_address = true });
    const tl = try TCPListener.init(allocator, io, server);
    return tl.listener();
}

/// Dialer contains options for connecting to an address.
pub const Dialer = struct {
    timeout: ?Duration = null,
    deadline: ?Time = null,
    local_addr: ?[]const u8 = null,
    keep_alive: ?Duration = null,

    pub fn dial(self: Dialer, allocator: std.mem.Allocator, io: std.Io, network: []const u8, address: []const u8) !Conn {
        return self.dialContext(allocator, io, context.background(), network, address);
    }

    pub fn dialContext(
        self: Dialer,
        allocator: std.mem.Allocator,
        io: std.Io,
        ctx: Context,
        network: []const u8,
        address: []const u8,
    ) !Conn {
        if (ctx.err()) |e| return e;

        if (!std.mem.startsWith(u8, network, "tcp")) {
            return error.UnknownNetwork;
        }

        const hp = try hostport.splitHostPort(address);
        const port = std.fmt.parseInt(u16, hp.port, 10) catch return error.InvalidPort;

        // Note: Zig 0.17.0 std.Io.Threaded netConnectIpPosix panics if options.timeout != .none:
        // "TODO implement netConnectIpPosix with timeout".
        // Until upstream implements POSIX connect timeout in std.Io, we must pass .none to avoid panic.
        const timeout_io: std.Io.Timeout = .none;
        _ = self.timeout;

        var stream: std.Io.net.Stream = undefined;

        if (std.Io.net.IpAddress.parse(hp.host, port)) |ip| {
            stream = try ip.connect(io, .{ .mode = .stream, .timeout = timeout_io });
        } else |_| {
            var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
            if (hp.host.len > host_buf.len) return error.HostNameTooLong;
            @memcpy(host_buf[0..hp.host.len], hp.host);
            const host_name = try std.Io.net.HostName.init(host_buf[0..hp.host.len]);
            stream = try host_name.connect(io, port, .{ .mode = .stream, .timeout = timeout_io });
        }
        errdefer stream.close(io);

        if (ctx.err()) |e| return e;

        const sc = try StreamConn.init(allocator, io, stream, address);
        return sc.conn();
    }
};

/// DialContext connects to the address on the named network using the provided context.
pub fn dialContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: Context,
    network: []const u8,
    address: []const u8,
) !Conn {
    const d = Dialer{};
    return d.dialContext(allocator, io, ctx, network, address);
}

/// Dial connects to the address on the named network.
pub fn dial(
    allocator: std.mem.Allocator,
    io: std.Io,
    network: []const u8,
    address: []const u8,
) !Conn {
    return dialContext(allocator, io, context.background(), network, address);
}

// -------------------------------------------------------------------------
// In-Memory Bidirectional Pipe (Go net.Pipe())
// -------------------------------------------------------------------------

const Mutex = @import("../sync/mutex.zig").Mutex;

const PipeQueue = struct {
    buf: [4096]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,
    mutex: Mutex = .{},

    fn write(self: *PipeQueue, data: []const u8) anyerror!usize {
        var written: usize = 0;
        while (written < data.len) {
            self.mutex.lock();
            if (self.closed) {
                self.mutex.unlock();
                return error.BrokenPipe;
            }
            if (self.count == self.buf.len) {
                self.mutex.unlock();
                std.Thread.yield() catch {};
                continue;
            }
            const avail = self.buf.len - self.count;
            const chunk = @min(data.len - written, avail);
            for (0..chunk) |i| {
                self.buf[self.tail] = data[written + i];
                self.tail = (self.tail + 1) % self.buf.len;
            }
            self.count += chunk;
            written += chunk;
            self.mutex.unlock();
        }
        return written;
    }

    fn read(self: *PipeQueue, out: []u8) anyerror!usize {
        if (out.len == 0) return 0;
        while (true) {
            self.mutex.lock();
            if (self.count > 0) {
                const chunk = @min(out.len, self.count);
                for (0..chunk) |i| {
                    out[i] = self.buf[self.head];
                    self.head = (self.head + 1) % self.buf.len;
                }
                self.count -= chunk;
                self.mutex.unlock();
                return chunk;
            }
            if (self.closed) {
                self.mutex.unlock();
                return 0; // EOF
            }
            self.mutex.unlock();
            std.Thread.yield() catch {};
        }
    }

    fn close(self: *PipeQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
    }
};

const PipeState = struct {
    allocator: std.mem.Allocator,
    q12: PipeQueue = .{},
    q21: PipeQueue = .{},
    refcount: usize = 2,
    state_mutex: Mutex = .{},

    fn destroyIfDone(self: *PipeState) void {
        self.state_mutex.lock();
        self.refcount -= 1;
        const is_zero = (self.refcount == 0);
        self.state_mutex.unlock();
        if (is_zero) {
            self.allocator.destroy(self);
        }
    }
};

const PipeEndpoint = struct {
    state: *PipeState,
    in_q: *PipeQueue,
    out_q: *PipeQueue,

    fn conn(self: *PipeEndpoint) Conn {
        return .{
            .ptr = self,
            .vtable = &endpoint_vtable,
        };
    }

    fn readImpl(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *PipeEndpoint = @ptrCast(@alignCast(ctx));
        return self.in_q.read(buf);
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!usize {
        const self: *PipeEndpoint = @ptrCast(@alignCast(ctx));
        return self.out_q.write(data);
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *PipeEndpoint = @ptrCast(@alignCast(ctx));
        self.out_q.close();
        self.in_q.close();
        const st = self.state;
        const alloc = st.allocator;
        alloc.destroy(self);
        st.destroyIfDone();
    }

    const endpoint_vtable: Conn.VTable = .{
        .read = readImpl,
        .write = writeImpl,
        .close = closeImpl,
    };
};

pub const PipePair = struct {
    conn1: Conn,
    conn2: Conn,
};

/// Pipe creates a synchronous, in-memory full-duplex network connection;
/// both ends implement the Conn interface.
/// Reads on one end are matched with writes on the other.
pub fn pipe(allocator: std.mem.Allocator) !PipePair {
    const st = try allocator.create(PipeState);
    st.* = .{
        .allocator = allocator,
    };

    const ep1 = try allocator.create(PipeEndpoint);
    ep1.* = .{
        .state = st,
        .in_q = &st.q21,
        .out_q = &st.q12,
    };

    const ep2 = try allocator.create(PipeEndpoint);
    ep2.* = .{
        .state = st,
        .in_q = &st.q12,
        .out_q = &st.q21,
    };

    return .{
        .conn1 = ep1.conn(),
        .conn2 = ep2.conn(),
    };
}
