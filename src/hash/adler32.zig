const std = @import("std");
const testing = std.testing;
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;
const Hash32 = hash_mod.Hash32;

/// The size of an Adler-32 checksum in bytes.
pub const Size: usize = 4;
pub const size = Size;

const mod: u32 = 65521;
const nmax: usize = 5552;

/// update returns the result of adding the bytes in p to the adler checksum.
pub fn update(adler_in: u32, p: []const u8) u32 {
    var s1: u32 = adler_in & 0xffff;
    var s2: u32 = (adler_in >> 16) & 0xffff;

    var input = p;
    while (input.len > 0) {
        const chunk_len = @min(input.len, nmax);
        const chunk = input[0..chunk_len];
        input = input[chunk_len..];

        for (chunk) |b| {
            s1 += b;
            s2 += s1;
        }
        s1 %= mod;
        s2 %= mod;
    }

    return (s2 << 16) | s1;
}

/// checksum returns the Adler-32 checksum of data.
pub fn checksum(data: []const u8) u32 {
    return update(1, data);
}

/// Digest implements the streaming Adler-32 state.
pub const Digest = struct {
    a: u32 = 1,

    pub fn init() Digest {
        return .{ .a = 1 };
    }

    pub fn reset(self: *Digest) void {
        self.a = 1;
    }

    pub fn write(self: *Digest, bytes: []const u8) usize {
        self.a = update(self.a, bytes);
        return bytes.len;
    }

    pub fn sum32(self: *const Digest) u32 {
        return self.a;
    }

    pub fn size(_: *const Digest) usize {
        return Size;
    }

    pub fn blockSize(_: *const Digest) usize {
        return 4;
    }

    pub fn sum(self: *const Digest, out: []u8) []const u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.a, .big);
        const copy_len = @min(out.len, 4);
        @memcpy(out[0..copy_len], buf[0..copy_len]);
        return out[0..copy_len];
    }

    pub fn hash32(self: *Digest) Hash32 {
        return .{
            .ptr = self,
            .vtable = &hash32_vtable,
        };
    }

    pub fn hash(self: *Digest) Hash {
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
        const self: *Digest = @ptrCast(@alignCast(ctx));
        return self.write(bytes);
    }

    fn vtableSum(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *const Digest = @ptrCast(@alignCast(ctx));
        return self.sum(out);
    }

    fn vtableReset(ctx: *anyopaque) void {
        const self: *Digest = @ptrCast(@alignCast(ctx));
        self.reset();
    }

    fn vtableSize(_: *anyopaque) usize {
        return Size;
    }

    fn vtableBlockSize(_: *anyopaque) usize {
        return 4;
    }

    fn vtableSum32(ctx: *anyopaque) u32 {
        const self: *const Digest = @ptrCast(@alignCast(ctx));
        return self.sum32();
    }
};

/// new returns a new Digest computing the Adler-32 checksum.
pub fn new() Digest {
    return Digest.init();
}

test "adler32: checksum test vectors" {
    // Official test vector for "123456789"
    try testing.expectEqual(@as(u32, 0x091e01de), checksum("123456789"));
    // Empty input is 1
    try testing.expectEqual(@as(u32, 1), checksum(""));
}

test "adler32: streaming Digest and Hash32 interface" {
    var d = new();
    _ = d.write("1234");
    _ = d.write("56789");
    try testing.expectEqual(@as(u32, 0x091e01de), d.sum32());

    var out_buf: [4]u8 = undefined;
    const s = d.sum(&out_buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x09, 0x1e, 0x01, 0xde }, s);

    var h32 = d.hash32();
    h32.reset();
    try testing.expectEqual(@as(u32, 1), h32.sum32());
    _ = try h32.write("123456789");
    try testing.expectEqual(@as(u32, 0x091e01de), h32.sum32());
}
