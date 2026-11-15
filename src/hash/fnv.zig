const std = @import("std");
const testing = std.testing;
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;
const Hash32 = hash_mod.Hash32;
const Hash64 = hash_mod.Hash64;

const prime32: u32 = 0x01000193; // 16777619
const offset32: u32 = 0x811c9dc5; // 2166136261

const prime64: u64 = 0x100000001b3; // 1099511628211
const offset64: u64 = 0xcbf29ce484222325; // 14695981039346656037

pub const Mode = enum {
    fnv1,
    fnv1a,
};

/// Digest32 represents a 32-bit FNV hash state.
pub const Digest32 = struct {
    val: u32 = offset32,
    mode: Mode,

    pub fn init(mode: Mode) Digest32 {
        return .{
            .val = offset32,
            .mode = mode,
        };
    }

    pub fn reset(self: *Digest32) void {
        self.val = offset32;
    }

    pub fn write(self: *Digest32, bytes: []const u8) usize {
        switch (self.mode) {
            .fnv1 => {
                for (bytes) |b| {
                    self.val = (self.val *% prime32) ^ b;
                }
            },
            .fnv1a => {
                for (bytes) |b| {
                    self.val = (self.val ^ b) *% prime32;
                }
            },
        }
        return bytes.len;
    }

    pub fn sum32(self: *const Digest32) u32 {
        return self.val;
    }

    pub fn size(_: *const Digest32) usize {
        return 4;
    }

    pub fn blockSize(_: *const Digest32) usize {
        return 1;
    }

    pub fn sum(self: *const Digest32, out: []u8) []const u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.val, .big);
        const copy_len = @min(out.len, 4);
        @memcpy(out[0..copy_len], buf[0..copy_len]);
        return out[0..copy_len];
    }

    pub fn hash32(self: *Digest32) Hash32 {
        return .{
            .ptr = self,
            .vtable = &hash32_vtable,
        };
    }

    pub fn hash(self: *Digest32) Hash {
        return self.hash32().hash();
    }

    const hash32_vtable: Hash32.VTable = .{
        .hash = .{
            .write = vtableWrite,
            .sum = vtableSum,
            .reset = vtableReset,
            .size = vtableSize,
            .blockSize = vtableBlockSize,
        },
        .sum32 = vtableSum32,
    };

    fn vtableWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Digest32 = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }

    fn vtableSum(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *const Digest32 = @ptrCast(@alignCast(ctx));
        return self.sum(out);
    }

    fn vtableReset(ctx: *anyopaque) void {
        const self: *Digest32 = @ptrCast(@alignCast(ctx));
        self.reset();
    }

    fn vtableSize(_: *anyopaque) usize {
        return 4;
    }

    fn vtableBlockSize(_: *anyopaque) usize {
        return 1;
    }

    fn vtableSum32(ctx: *anyopaque) u32 {
        const self: *const Digest32 = @ptrCast(@alignCast(ctx));
        return self.sum32();
    }
};

/// Digest64 represents a 64-bit FNV hash state.
pub const Digest64 = struct {
    val: u64 = offset64,
    mode: Mode,

    pub fn init(mode: Mode) Digest64 {
        return .{
            .val = offset64,
            .mode = mode,
        };
    }

    pub fn reset(self: *Digest64) void {
        self.val = offset64;
    }

    pub fn write(self: *Digest64, bytes: []const u8) usize {
        switch (self.mode) {
            .fnv1 => {
                for (bytes) |b| {
                    self.val = (self.val *% prime64) ^ b;
                }
            },
            .fnv1a => {
                for (bytes) |b| {
                    self.val = (self.val ^ b) *% prime64;
                }
            },
        }
        return bytes.len;
    }

    pub fn sum64(self: *const Digest64) u64 {
        return self.val;
    }

    pub fn size(_: *const Digest64) usize {
        return 8;
    }

    pub fn blockSize(_: *const Digest64) usize {
        return 1;
    }

    pub fn sum(self: *const Digest64, out: []u8) []const u8 {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, self.val, .big);
        const copy_len = @min(out.len, 8);
        @memcpy(out[0..copy_len], buf[0..copy_len]);
        return out[0..copy_len];
    }

    pub fn hash64(self: *Digest64) Hash64 {
        return .{
            .ptr = self,
            .vtable = &hash64_vtable,
        };
    }

    pub fn hash(self: *Digest64) Hash {
        return self.hash64().hash();
    }

    const hash64_vtable: Hash64.VTable = .{
        .hash = .{
            .write = vtableWrite,
            .sum = vtableSum,
            .reset = vtableReset,
            .size = vtableSize,
            .blockSize = vtableBlockSize,
        },
        .sum64 = vtableSum64,
    };

    fn vtableWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Digest64 = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }

    fn vtableSum(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *const Digest64 = @ptrCast(@alignCast(ctx));
        return self.sum(out);
    }

    fn vtableReset(ctx: *anyopaque) void {
        const self: *Digest64 = @ptrCast(@alignCast(ctx));
        self.reset();
    }

    fn vtableSize(_: *anyopaque) usize {
        return 8;
    }

    fn vtableBlockSize(_: *anyopaque) usize {
        return 1;
    }

    fn vtableSum64(ctx: *anyopaque) u64 {
        const self: *const Digest64 = @ptrCast(@alignCast(ctx));
        return self.sum64();
    }
};

/// new32 returns a new 32-bit FNV-1 hash.Hash32.
pub fn new32() Digest32 {
    return Digest32.init(.fnv1);
}

/// new32a returns a new 32-bit FNV-1a hash.Hash32.
pub fn new32a() Digest32 {
    return Digest32.init(.fnv1a);
}

/// new64 returns a new 64-bit FNV-1 hash.Hash64.
pub fn new64() Digest64 {
    return Digest64.init(.fnv1);
}

/// new64a returns a new 64-bit FNV-1a hash.Hash64.
pub fn new64a() Digest64 {
    return Digest64.init(.fnv1a);
}

pub fn fnv32(data: []const u8) u32 {
    var d = new32();
    _ = d.write(data);
    return d.sum32();
}

pub fn fnv32a(data: []const u8) u32 {
    var d = new32a();
    _ = d.write(data);
    return d.sum32();
}

pub fn fnv64(data: []const u8) u64 {
    var d = new64();
    _ = d.write(data);
    return d.sum64();
}

pub fn fnv64a(data: []const u8) u64 {
    var d = new64a();
    _ = d.write(data);
    return d.sum64();
}

test "fnv: 32-bit and 64-bit test vectors" {
    try testing.expectEqual(@as(u32, 0x811c9dc5), fnv32(""));
    try testing.expectEqual(@as(u32, 0x811c9dc5), fnv32a(""));
    try testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv64(""));
    try testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv64a(""));

    try testing.expectEqual(@as(u32, 0x24148816), fnv32("123456789"));
    try testing.expectEqual(@as(u32, 0xbb86b11c), fnv32a("123456789"));
    try testing.expectEqual(@as(u64, 0xa72ffc362bf916d6), fnv64("123456789"));
    try testing.expectEqual(@as(u64, 0x6d5573923c6cdfc), fnv64a("123456789"));

    // Standard foobar
    try testing.expectEqual(@as(u32, 0xbf9cf968), fnv32a("foobar"));
    try testing.expectEqual(@as(u64, 0x85944171f73967e8), fnv64a("foobar"));
}

test "fnv: streaming and Hash32/Hash64 interface" {
    var d32 = new32a();
    _ = d32.write("foo");
    _ = d32.write("bar");
    try testing.expectEqual(@as(u32, 0xbf9cf968), d32.sum32());

    var h32 = d32.hash32();
    h32.reset();
    _ = try h32.write("foobar");
    try testing.expectEqual(@as(u32, 0xbf9cf968), h32.sum32());

    var d64 = new64a();
    _ = d64.write("foobar");
    try testing.expectEqual(@as(u64, 0x85944171f73967e8), d64.sum64());

    var h64 = d64.hash64();
    h64.reset();
    _ = try h64.write("foobar");
    try testing.expectEqual(@as(u64, 0x85944171f73967e8), h64.sum64());
}
