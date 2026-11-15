//! Package utf16 implements encoding and decoding of UTF-16 sequences,
//! conforming to Go's unicode/utf16 package.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// The Unicode replacement character, U+FFFD.
pub const ReplacementChar: u21 = 0xFFFD;

/// The maximum valid Unicode code point.
pub const MaxRune: u21 = 0x10FFFF;

const surr1: u32 = 0xd800;
const surr2: u32 = 0xdc00;
const surr3: u32 = 0xe000;
const surr_self: u32 = 0x10000;

/// IsSurrogate reports whether the specified Unicode code point
/// can appear in a surrogate pair.
pub fn isSurrogate(r: u32) bool {
    return surr1 <= r and r < surr3;
}

/// DecodeRune returns the UTF-16 decoding of a surrogate pair.
/// If the pair is not a valid UTF-16 surrogate pair, DecodeRune returns
/// the Unicode replacement character U+FFFD.
pub fn decodeRune(r1: u16, r2: u16) u32 {
    const r1_32: u32 = r1;
    const r2_32: u32 = r2;
    if (surr1 <= r1_32 and r1_32 < surr2 and surr2 <= r2_32 and r2_32 < surr3) {
        return (((r1_32 - surr1) << 10) | (r2_32 - surr2)) + surr_self;
    }
    return ReplacementChar;
}

/// EncodeRune returns the UTF-16 surrogate pair for the given code point.
/// If the rune is not a valid Unicode code point that requires a surrogate pair,
/// EncodeRune returns (ReplacementChar, ReplacementChar).
pub fn encodeRune(r: u32) struct { r1: u16, r2: u16 } {
    if (r < surr_self or r > MaxRune) {
        return .{ .r1 = @intCast(ReplacementChar), .r2 = @intCast(ReplacementChar) };
    }
    const val = r - surr_self;
    const r1: u16 = @intCast(surr1 + ((val >> 10) & 0x3ff));
    const r2: u16 = @intCast(surr2 + (val & 0x3ff));
    return .{ .r1 = r1, .r2 = r2 };
}

/// Encode returns the UTF-16 encoding of the Unicode code points s.
pub fn encode(allocator: Allocator, s: []const u32) ![]u16 {
    var out = std.ArrayList(u16).empty;
    defer out.deinit(allocator);

    for (s) |r| {
        if (r < surr_self and !isSurrogate(r)) {
            try out.append(allocator, @intCast(r));
        } else if (r >= surr_self and r <= MaxRune) {
            const pair = encodeRune(r);
            try out.append(allocator, pair.r1);
            try out.append(allocator, pair.r2);
        } else {
            try out.append(allocator, @intCast(ReplacementChar));
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Decode returns the Unicode code points represented by the UTF-16 encoding s.
pub fn decode(allocator: Allocator, s: []const u16) ![]u32 {
    var out = std.ArrayList(u32).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        const u = s[i];
        if (u < surr1 or u >= surr3) {
            // Normal 16-bit BMP character
            try out.append(allocator, u);
            i += 1;
        } else if (u < surr2 and i + 1 < s.len and s[i + 1] >= surr2 and s[i + 1] < surr3) {
            // Valid surrogate pair
            const rune = decodeRune(u, s[i + 1]);
            try out.append(allocator, rune);
            i += 2;
        } else {
            // Unpaired surrogate
            try out.append(allocator, ReplacementChar);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "utf16 surrogate checks and rune encoding" {
    const testing = std.testing;

    try testing.expect(!isSurrogate('a'));
    try testing.expect(isSurrogate(0xd800));
    try testing.expect(isSurrogate(0xdfff));
    try testing.expect(!isSurrogate(0xe000));

    // Musical symbol G Clef: U+1D11E
    const g_clef: u32 = 0x1D11E;
    const pair = encodeRune(g_clef);
    try testing.expectEqual(@as(u16, 0xD834), pair.r1);
    try testing.expectEqual(@as(u16, 0xDD1E), pair.r2);

    const decoded_rune = decodeRune(pair.r1, pair.r2);
    try testing.expectEqual(g_clef, decoded_rune);

    // Invalid surrogate decoding
    try testing.expectEqual(ReplacementChar, decodeRune(0x1234, 0x5678));
}

test "utf16 encode and decode slice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // "Hello, 世界" + G Clef (0x1D11E)
    const runes = [_]u32{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 0x4E16, 0x754C, 0x1D11E };

    const encoded = try encode(allocator, &runes);
    defer allocator.free(encoded);

    // Check G Clef encoded as two u16s
    try testing.expectEqual(runes.len + 1, encoded.len);
    try testing.expectEqual(@as(u16, 0xD834), encoded[encoded.len - 2]);
    try testing.expectEqual(@as(u16, 0xDD1E), encoded[encoded.len - 1]);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqualSlices(u32, &runes, decoded);
}

test "utf16 decode unpaired surrogates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const invalid = [_]u16{ 0xD834, 'a' }; // Unpaired high surrogate
    const decoded = try decode(allocator, &invalid);
    defer allocator.free(decoded);

    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqual(ReplacementChar, decoded[0]);
    try testing.expectEqual(@as(u32, 'a'), decoded[1]);
}
