//! Example demonstrating stdgo.bufio Scanner.
//!
//! Run with: zig build run-bufio

const std = @import("std");
const stdgo = @import("stdgo");
const bufio = stdgo.bufio;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo bufio.Scanner Demo ===\n\n", .{});

    // 1. Line-by-line scanning (default scanLines)
    const log_data =
        \\2026-11-14 22:00:01 INFO Server starting up on 0.0.0.0:8080
        \\2026-11-14 22:00:02 INFO Database connected successfully
        \\2026-11-14 22:00:05 WARN High memory usage detected (82%)
        \\2026-11-14 22:00:10 ERROR Connection timed out to replica-1
    ;

    var r_lines = bytes.Reader.init(log_data);
    var line_scanner = try bufio.Scanner.init(allocator, r_lines.reader());
    defer line_scanner.deinit();

    std.debug.print("1. Line Scanning (scanLines):\n", .{});
    var line_num: usize = 1;
    while (line_scanner.scan()) {
        std.debug.print("   [{d}] {s}\n", .{ line_num, line_scanner.text() });
        line_num += 1;
    }
    if (line_scanner.err()) |err| {
        std.debug.print("   Scan error: {s}\n", .{@errorName(err)});
    }
    std.debug.print("\n", .{});

    // 2. Word-by-word scanning (scanWords)
    const prose = "The quick brown fox jumps over the lazy dog";
    var r_words = bytes.Reader.init(prose);
    var word_scanner = try bufio.Scanner.init(allocator, r_words.reader());
    defer word_scanner.deinit();
    word_scanner.split(bufio.scanWords);

    std.debug.print("2. Word Scanning (scanWords):\n   Words: ", .{});
    var word_idx: usize = 0;
    while (word_scanner.scan()) {
        if (word_idx > 0) std.debug.print(", ", .{});
        std.debug.print("'{s}'", .{word_scanner.text()});
        word_idx += 1;
    }
    std.debug.print(" (total: {d})\n\n", .{word_idx});

    // 3. UTF-8 Rune-by-Rune scanning (scanRunes)
    const greeting = "Hello, 世界 🚀!";
    var r_runes = bytes.Reader.init(greeting);
    var rune_scanner = try bufio.Scanner.init(allocator, r_runes.reader());
    defer rune_scanner.deinit();
    rune_scanner.split(bufio.scanRunes);

    std.debug.print("3. Rune Scanning (scanRunes):\n   Runes: [", .{});
    var rune_idx: usize = 0;
    while (rune_scanner.scan()) {
        if (rune_idx > 0) std.debug.print(" ", .{});
        std.debug.print("{s}", .{rune_scanner.text()});
        rune_idx += 1;
    }
    std.debug.print("]\n\n", .{});

    std.debug.print("=== Demo Complete ===\n", .{});
}
