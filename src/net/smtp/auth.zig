//! RFC 4616 (PLAIN) and RFC 2195 (CRAM-MD5) SMTP Authentication.
const std = @import("std");
const hmac = @import("../../crypto/hmac.zig");
const hex = @import("../../encoding/hex.zig");
const Allocator = std.mem.Allocator;

pub const ServerInfo = struct {
    name: []const u8,
    tls: bool = false,
    auth: []const []const u8 = &.{},
};

pub const Auth = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const StartResult = struct {
        proto: []const u8,
        to_server: ?[]const u8 = null,
    };

    pub const VTable = struct {
        start: *const fn (ctx: *anyopaque, server: ServerInfo) anyerror!StartResult,
        next: *const fn (ctx: *anyopaque, from_server: []const u8, more: bool) anyerror!?[]const u8,
        deinit: ?*const fn (ctx: *anyopaque) void = null,
    };

    pub fn start(self: Auth, server: ServerInfo) anyerror!StartResult {
        return self.vtable.start(self.ptr, server);
    }

    pub fn next(self: Auth, from_server: []const u8, more: bool) anyerror!?[]const u8 {
        return self.vtable.next(self.ptr, from_server, more);
    }

    pub fn deinit(self: Auth) void {
        if (self.vtable.deinit) |f| f(self.ptr);
    }
};

fn isLocalhost(name: []const u8) bool {
    return std.mem.eql(u8, name, "localhost") or
        std.mem.eql(u8, name, "127.0.0.1") or
        std.mem.eql(u8, name, "::1");
}

pub const PlainAuthImpl = struct {
    allocator: Allocator,
    identity: []const u8,
    username: []const u8,
    password: []const u8,
    host: []const u8,

    pub fn auth(self: *PlainAuthImpl) Auth {
        return .{
            .ptr = self,
            .vtable = &plain_auth_vtable,
        };
    }

    fn startImpl(ctx: *anyopaque, server: ServerInfo) anyerror!Auth.StartResult {
        const self: *PlainAuthImpl = @ptrCast(@alignCast(ctx));
        if (!server.tls and !isLocalhost(server.name)) {
            return error.UnencryptedConnection;
        }
        if (!std.mem.eql(u8, server.name, self.host)) {
            return error.WrongHostName;
        }

        // RFC 4616: [authzid] UTF8NUL authcid UTF8NUL passwd
        const total_len = self.identity.len + 1 + self.username.len + 1 + self.password.len;
        const resp = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        @memcpy(resp[pos .. pos + self.identity.len], self.identity);
        pos += self.identity.len;
        resp[pos] = 0;
        pos += 1;

        @memcpy(resp[pos .. pos + self.username.len], self.username);
        pos += self.username.len;
        resp[pos] = 0;
        pos += 1;

        @memcpy(resp[pos .. pos + self.password.len], self.password);

        return .{
            .proto = "PLAIN",
            .to_server = resp,
        };
    }

    fn nextImpl(ctx: *anyopaque, from_server: []const u8, more: bool) anyerror!?[]const u8 {
        _ = ctx;
        _ = from_server;
        if (more) {
            return error.UnexpectedServerChallenge;
        }
        return null;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *PlainAuthImpl = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }

    const plain_auth_vtable: Auth.VTable = .{
        .start = startImpl,
        .next = nextImpl,
        .deinit = deinitImpl,
    };
};

/// PlainAuth returns an Auth that implements the PLAIN authentication mechanism
/// as defined in RFC 4616.
pub fn plainAuth(
    allocator: Allocator,
    identity: []const u8,
    username: []const u8,
    password: []const u8,
    host: []const u8,
) !Auth {
    const impl = try allocator.create(PlainAuthImpl);
    impl.* = .{
        .allocator = allocator,
        .identity = identity,
        .username = username,
        .password = password,
        .host = host,
    };
    return impl.auth();
}

pub const CramMD5AuthImpl = struct {
    allocator: Allocator,
    username: []const u8,
    secret: []const u8,

    pub fn auth(self: *CramMD5AuthImpl) Auth {
        return .{
            .ptr = self,
            .vtable = &cram_md5_auth_vtable,
        };
    }

    fn startImpl(ctx: *anyopaque, server: ServerInfo) anyerror!Auth.StartResult {
        _ = ctx;
        _ = server;
        return .{
            .proto = "CRAM-MD5",
            .to_server = null,
        };
    }

    fn nextImpl(ctx: *anyopaque, from_server: []const u8, more: bool) anyerror!?[]const u8 {
        const self: *CramMD5AuthImpl = @ptrCast(@alignCast(ctx));
        if (!more) return null;

        // Compute HMAC-MD5 over the challenge
        var digest: [16]u8 = undefined;
        hmac.md5(self.secret, from_server, &digest);

        // Format username + " " + hex(digest)
        var hex_buf: [32]u8 = undefined;
        _ = hex.encode(&hex_buf, &digest);

        const total_len = self.username.len + 1 + hex_buf.len;
        const out = try self.allocator.alloc(u8, total_len);
        @memcpy(out[0..self.username.len], self.username);
        out[self.username.len] = ' ';
        @memcpy(out[self.username.len + 1 ..], &hex_buf);

        return out;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *CramMD5AuthImpl = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }

    const cram_md5_auth_vtable: Auth.VTable = .{
        .start = startImpl,
        .next = nextImpl,
        .deinit = deinitImpl,
    };
};

/// CRAMMD5Auth returns an Auth that implements the CRAM-MD5 authentication
/// mechanism as defined in RFC 2195.
pub fn cramMD5Auth(allocator: Allocator, username: []const u8, secret: []const u8) !Auth {
    const impl = try allocator.create(CramMD5AuthImpl);
    impl.* = .{
        .allocator = allocator,
        .username = username,
        .secret = secret,
    };
    return impl.auth();
}
