const std = @import("std");
const testing = std.testing;
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;
const Hash32 = hash_mod.Hash32;

/// IEEE polynomial (reversed: 0xedb88320). Used by Ethernet (IEEE 802.3), vmv, gzip, zip, png, etc.
pub const IEEE: u32 = 0xedb88320;

/// Castagnoli's polynomial (reversed: 0x82f63b78). Used by iSCSI, Btrfs, ext4, SCTP.
pub const Castagnoli: u32 = 0x82f63b78;

/// Koopman's polynomial (reversed: 0xeb31d82e).
pub const Koopman: u32 = 0xeb31d82e;

/// The size of a CRC-32 checksum in bytes.
pub const Size: usize = 4;
pub const size = Size;

/// Table is a 256-word lookup table for polynomial division.
pub const Table = [256]u32;

/// makeTable constructs a Table from the given polynomial.
pub fn makeTable(poly: u32) Table {
    @setEvalBranchQuota(5000);
    var t: Table = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ poly;
            } else {
                crc = crc >> 1;
            }
        }
        t[i] = crc;
    }
    return t;
}

pub const IEEETable: Table = makeTable(IEEE);
pub const CastagnoliTable: Table = makeTable(Castagnoli);
pub const KoopmanTable: Table = makeTable(Koopman);

/// update returns the result of adding the bytes in p to the crc.
pub fn update(crc_in: u32, tab: *const Table, p: []const u8) u32 {
    var crc = ~crc_in;
    for (p) |b| {
        const idx: usize = @as(u8, @truncate(crc)) ^ b;
        crc = tab[idx] ^ (crc >> 8);
    }
    return ~crc;
}

/// checksum returns the CRC-32 checksum of data using the specified polynomial table.
pub fn checksum(data: []const u8, tab: *const Table) u32 {
    return update(0, tab, data);
}

/// checksumIEEE returns the CRC-32 checksum of data using the IEEE polynomial.
pub fn checksumIEEE(data: []const u8) u32 {
    return update(0, &IEEETable, data);
}

/// Digest implements the streaming CRC-32 state.
pub const Digest = struct {
    crc: u32 = 0,
    tab: *const Table,

    pub fn init(tab: *const Table) Digest {
        return .{
            .crc = 0,
            .tab = tab,
        };
    }

    pub fn initIEEE() Digest {
        return init(&IEEETable);
    }

    pub fn reset(self: *Digest) void {
        self.crc = 0;
    }

    pub fn write(self: *Digest, bytes: []const u8) usize {
        self.crc = update(self.crc, self.tab, bytes);
        return bytes.len;
    }

    pub fn sum32(self: *const Digest) u32 {
        return self.crc;
    }

    pub fn size(_: *const Digest) usize {
        return Size;
    }

    pub fn blockSize(_: *const Digest) usize {
        return 1;
    }

    pub fn sum(self: *const Digest, out: []u8) []const u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.crc, .big);
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
        return 1;
    }

    fn vtableSum32(ctx: *anyopaque) u32 {
        const self: *const Digest = @ptrCast(@alignCast(ctx));
        return self.sum32();
    }
};

/// new creates a new Digest using the specified Table.
pub fn new(tab: *const Table) Digest {
    return Digest.init(tab);
}

/// newIEEE creates a new Digest using the IEEE Table.
pub fn newIEEE() Digest {
    return Digest.initIEEE();
}

test "crc32: checksum IEEE and Castagnoli test vectors" {
    // Official test vector for "123456789"
    try testing.expectEqual(@as(u32, 0xcbf43926), checksumIEEE("123456789"));
    try testing.expectEqual(@as(u32, 0xe3069283), checksum("123456789", &CastagnoliTable));

    // Empty input
    try testing.expectEqual(@as(u32, 0x0), checksumIEEE(""));
    try testing.expectEqual(@as(u32, 0x0), checksum("", &CastagnoliTable));
}

test "crc32: streaming Digest and Hash32 interface" {
    var d = newIEEE();
    _ = d.write("1234");
    _ = d.write("56789");
    try testing.expectEqual(@as(u32, 0xcbf43926), d.sum32());

    var out_buf: [4]u8 = undefined;
    const s = d.sum(&out_buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xcb, 0xf4, 0x39, 0x26 }, s);

    // Hash32 interface
    var h32 = d.hash32();
    h32.reset();
    try testing.expectEqual(@as(u32, 0), h32.sum32());
    _ = try h32.write("123456789");
    try testing.expectEqual(@as(u32, 0xcbf43926), h32.sum32());

    // Hash interface
    const h = h32.hash();
    try testing.expectEqual(@as(usize, 4), h.size());
    try testing.expectEqual(@as(usize, 1), h.blockSize());
}
