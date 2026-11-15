//! Example demonstrating stdgo.unicode.utf8:
//! Full UTF-8 code point decoding, encoding, character count, and validity checking.

const std = @import("std");
const stdgo = @import("stdgo");
const utf8 = stdgo.unicode.utf8;

pub fn main(_: std.process.Init) !void {
    std.debug.print("=== stdgo unicode/utf8 Encoding & Decoding Demo ===\n\n", .{});

    const text = "Hello, 世界 🌍! Zig & Go.";

    // 1. Character count vs byte length
    const byte_len = text.len;
    const rune_count = utf8.runeCountInString(text);
    std.debug.print("1. Text: \"{s}\"\n", .{text});
    std.debug.print("   -> Byte length: {d}\n", .{byte_len});
    std.debug.print("   -> Rune (character) count: {d}\n\n", .{rune_count});

    // 2. Sequential forward decoding (decodeRune)
    std.debug.print("2. Sequential Rune Decoding:\n", .{});
    var slice: []const u8 = text;
    var idx: usize = 0;
    while (slice.len > 0) {
        const dec = utf8.decodeRuneInString(slice);
        std.debug.print("   [{d}] U+{X:0>4} (width: {d} bytes)\n", .{ idx, dec.rune, dec.size });
        slice = slice[dec.size..];
        idx += 1;
        if (idx >= 6) {
            std.debug.print("   ... (remaining {d} runes omitted for brevity)\n", .{rune_count - idx});
            break;
        }
    }
    std.debug.print("\n", .{});

    // 3. Reverse decoding (decodeLastRune)
    std.debug.print("3. Reverse Decoding from End:\n", .{});
    const last1 = utf8.decodeLastRuneInString(text);
    std.debug.print("   -> Last rune: U+{X:0>4} (width: {d} bytes)\n", .{ last1.rune, last1.size });
    const text_without_last = text[0 .. text.len - last1.size];
    const last2 = utf8.decodeLastRuneInString(text_without_last);
    std.debug.print("   -> Second to last rune: U+{X:0>4} (width: {d} bytes)\n\n", .{ last2.rune, last2.size });

    // 4. Encoding code points into UTF-8 bytes (encodeRune)
    std.debug.print("4. Encoding Runes to UTF-8:\n", .{});
    const test_runes = [_]u21{ 'A', 0x4E2D, 0x1F680 }; // 'A', '中', '🚀'
    for (test_runes) |r| {
        var buf: [utf8.UTFMax]u8 = undefined;
        const n = utf8.encodeRune(&buf, r);
        std.debug.print("   -> Encoded U+{X:0>4} -> {s} ({d} bytes)\n", .{ r, buf[0..n], n });
    }
    std.debug.print("\n", .{});

    // 5. UTF-8 Validation
    std.debug.print("5. Validation Checks:\n", .{});
    std.debug.print("   -> validString(\"{s}\"): {s}\n", .{ text, if (utf8.validString(text)) "VALID" else "INVALID" });

    const malformed = [_]u8{ 0xFF, 0xFE }; // Invalid UTF-8 bytes
    std.debug.print("   -> valid(0xFF 0xFE): {s}\n", .{if (utf8.valid(&malformed)) "VALID" else "INVALID"});

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
