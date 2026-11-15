//! Package encoding/ascii85 implements the ascii85 data encoding as used in
//! the btoa tool and Adobe's PostScript and PDF document formats.
//!
//! Encodes 4-byte binary blocks into 5 ASCII characters (in '!'..'u'), with special
//! 'z' zero-block compression.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// MaxEncodedLen returns the maximum length of an encoding of n source bytes.
pub fn maxEncodedLen(n: usize) usize {
    return ((n + 3) / 4) * 5;
}

/// Encode encodes src into dst using ascii85, returning the actual number of bytes written.
/// Full zero blocks (4 bytes of 0x00) are compressed to a single 'z' character.
pub fn encode(dst: []u8, src: []const u8) usize {
    if (src.len == 0) return 0;

    var di: usize = 0;
    var si: usize = 0;

    while (si + 4 <= src.len) : (si += 4) {
        const val = mem.readInt(u32, src[si..][0..4], .big);
        if (val == 0) {
            dst[di] = 'z';
            di += 1;
            continue;
        }

        var v = val;
        dst[di + 4] = @intCast((v % 85) + '!');
        v /= 85;
        dst[di + 3] = @intCast((v % 85) + '!');
        v /= 85;
        dst[di + 2] = @intCast((v % 85) + '!');
        v /= 85;
        dst[di + 1] = @intCast((v % 85) + '!');
        v /= 85;
        dst[di] = @intCast(v + '!');
        di += 5;
    }

    const remaining = src.len - si;
    if (remaining > 0) {
        var chunk: [4]u8 = @splat(0);
        @memcpy(chunk[0..remaining], src[si..]);
        var v = mem.readInt(u32, &chunk, .big);

        var buf: [5]u8 = undefined;
        buf[4] = @intCast((v % 85) + '!');
        v /= 85;
        buf[3] = @intCast((v % 85) + '!');
        v /= 85;
        buf[2] = @intCast((v % 85) + '!');
        v /= 85;
        buf[1] = @intCast((v % 85) + '!');
        v /= 85;
        buf[0] = @intCast(v + '!');

        const n = remaining + 1;
        @memcpy(dst[di .. di + n], buf[0..n]);
        di += n;
    }

    return di;
}

/// EncodeAlloc encodes src using ascii85, allocating the resulting slice.
pub fn encodeAlloc(allocator: Allocator, src: []const u8) ![]u8 {
    const max_len = maxEncodedLen(src.len);
    const buf = try allocator.alloc(u8, max_len);
    errdefer allocator.free(buf);
    const n = encode(buf, src);
    return try allocator.realloc(buf, n);
}

/// DecodeResult contains the count of uncompressed bytes written to dst and src bytes read.
pub const DecodeResult = struct {
    written: usize,
    read: usize,
};

/// Decode decodes ascii85-encoded src into dst, skipping whitespace and control characters.
pub fn decode(dst: []u8, src: []const u8) error{ CorruptInput, DestinationTooSmall }!DecodeResult {
    var di: usize = 0;
    var si: usize = 0;
    var group: [5]u8 = undefined;
    var group_len: usize = 0;

    while (si < src.len) : (si += 1) {
        const c = src[si];
        if (c <= ' ') continue; // Skip whitespace and control chars

        if (c == 'z') {
            if (group_len != 0) return error.CorruptInput;
            if (di + 4 > dst.len) return error.DestinationTooSmall;
            @memset(dst[di .. di + 4], 0);
            di += 4;
            continue;
        }

        if (c < '!' or c > 'u') return error.CorruptInput;
        group[group_len] = c - '!';
        group_len += 1;

        if (group_len == 5) {
            if (di + 4 > dst.len) return error.DestinationTooSmall;
            var val: u64 = 0;
            for (group) |digit| {
                val = val * 85 + digit;
            }
            if (val > 0xffffffff) return error.CorruptInput;
            mem.writeInt(u32, dst[di..][0..4], @intCast(val), .big);
            di += 4;
            group_len = 0;
        }
    }

    if (group_len > 0) {
        if (group_len == 1) return error.CorruptInput;
        const out_len = group_len - 1;
        if (di + out_len > dst.len) return error.DestinationTooSmall;

        // Pad with 'u' (value 84)
        for (group_len..5) |i| {
            group[i] = 84;
        }

        var val: u64 = 0;
        for (group) |digit| {
            val = val * 85 + digit;
        }
        if (val > 0xffffffff) return error.CorruptInput;

        var full_bytes: [4]u8 = undefined;
        mem.writeInt(u32, &full_bytes, @intCast(val), .big);
        @memcpy(dst[di .. di + out_len], full_bytes[0..out_len]);
        di += out_len;
    }

    return DecodeResult{
        .written = di,
        .read = si,
    };
}

pub fn decodeAlloc(allocator: Allocator, src: []const u8) ![]u8 {
    // Upper bound: 4 bytes per 5 encoded chars (plus 'z' expanding to 4)
    const upper_bound = src.len * 4 + 4;
    const buf = try allocator.alloc(u8, upper_bound);
    errdefer allocator.free(buf);
    const res = try decode(buf, src);
    return try allocator.realloc(buf, res.written);
}

test "encoding/ascii85 encode and decode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test "Attack at dawn"
    const enc1 = try encodeAlloc(allocator, "Attack at dawn");
    defer allocator.free(enc1);
    try testing.expectEqualStrings("6$.3W@r!2qF<G+&GA[", enc1);

    const dec1 = try decodeAlloc(allocator, enc1);
    defer allocator.free(dec1);
    try testing.expectEqualStrings("Attack at dawn", dec1);

    // Test "Man "
    const enc_man = try encodeAlloc(allocator, "Man ");
    defer allocator.free(enc_man);
    try testing.expectEqualStrings("9jqo^", enc_man);

    const dec_man = try decodeAlloc(allocator, enc_man);
    defer allocator.free(dec_man);
    try testing.expectEqualStrings("Man ", dec_man);

    // Test zero compression: 8 zero bytes -> "zz"
    const zeros = "\x00\x00\x00\x00\x00\x00\x00\x00";
    const enc_zeros = try encodeAlloc(allocator, zeros);
    defer allocator.free(enc_zeros);
    try testing.expectEqualStrings("zz", enc_zeros);

    const dec_zeros = try decodeAlloc(allocator, enc_zeros);
    defer allocator.free(dec_zeros);
    try testing.expectEqualStrings(zeros, dec_zeros);

    // Test round-trip with arbitrary binary payload
    const bin = "Go and Zig together create ultra fast reliable systems!";
    const enc_bin = try encodeAlloc(allocator, bin);
    defer allocator.free(enc_bin);
    const dec_bin = try decodeAlloc(allocator, enc_bin);
    defer allocator.free(dec_bin);
    try testing.expectEqualStrings(bin, dec_bin);
}
