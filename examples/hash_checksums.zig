//! Example demonstrating stdgo hash checksums:
//! CRC32 (IEEE, Castagnoli), Adler-32, and FNV-1 / FNV-1a (32-bit & 64-bit).

const std = @import("std");
const stdgo = @import("stdgo");
const crc32 = stdgo.hash.crc32;
const adler32 = stdgo.hash.adler32;
const fnv = stdgo.hash.fnv;

pub fn main(_: std.process.Init) !void {
    std.debug.print("=== stdgo Hash Checksums Demo ===\n\n", .{});

    const data = "123456789";
    std.debug.print("Input Payload: \"{s}\" (length: {d} bytes)\n\n", .{ data, data.len });

    // 1. CRC-32 (Cyclic Redundancy Check)
    std.debug.print("1. CRC-32:\n", .{});
    const crc_ieee = crc32.checksumIEEE(data);
    const crc_castagnoli = crc32.checksum(data, &crc32.CastagnoliTable);
    std.debug.print("   -> IEEE 802.3:  0x{X:0>8}\n", .{crc_ieee});
    std.debug.print("   -> Castagnoli:  0x{X:0>8}\n\n", .{crc_castagnoli});

    // 2. Adler-32 (RFC 1950)
    std.debug.print("2. Adler-32:\n", .{});
    const adler = adler32.checksum(data);
    std.debug.print("   -> Checksum:    0x{X:0>8}\n\n", .{adler});

    // 3. FNV-1 & FNV-1a (Fowler-Noll-Vo)
    std.debug.print("3. FNV Family:\n", .{});
    std.debug.print("   -> FNV-1  (32-bit): 0x{X:0>8}\n", .{fnv.fnv32(data)});
    std.debug.print("   -> FNV-1a (32-bit): 0x{X:0>8}\n", .{fnv.fnv32a(data)});
    std.debug.print("   -> FNV-1  (64-bit): 0x{X:0>16}\n", .{fnv.fnv64(data)});
    std.debug.print("   -> FNV-1a (64-bit): 0x{X:0>16}\n\n", .{fnv.fnv64a(data)});

    // 4. Streaming Hash32 Writer Interface
    std.debug.print("4. Streaming Checksum with io.Writer:\n", .{});
    var d = crc32.newIEEE();
    var h32 = d.hash32();
    const w = h32.writer();

    _ = try w.write("1234");
    _ = try w.write("56789");

    var out_bytes: [4]u8 = undefined;
    _ = h32.sum(&out_bytes);
    std.debug.print("   -> Streamed CRC32 IEEE: 0x{X:0>8} (raw bytes: {X:0>2} {X:0>2} {X:0>2} {X:0>2})\n", .{
        h32.sum32(),
        out_bytes[0],
        out_bytes[1],
        out_bytes[2],
        out_bytes[3],
    });

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
