//! Extended suite demonstration of Go standard library equivalents in Zig 0.17:
//! 1. strconv (Base conversion, float/int formatting, Go string quoting/unquoting)
//! 2. unicode.utf16 (Surrogate pairs, BMP & supplementary code point transcoding)
//! 3. html (Entity escaping and comprehensive numeric/named entity unescaping)
//! 4. image.gif (CompuServe GIF89a raster encoding & decoding with LSB LZW compression)

const std = @import("std");
const stdgo = @import("stdgo");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo Extended Standard Library Suite Demonstration ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. strconv: Data Conversions and Quoting
    // -------------------------------------------------------------
    std.debug.print("[1] strconv Demo:\n", .{});
    const parsed_int = try stdgo.strconv.parseInt("0x1f4", 0, 64);
    std.debug.print("    parseInt(\"0x1f4\", 0, 64)    = {d}\n", .{parsed_int});

    const parsed_bool = try stdgo.strconv.parseBool("TRUE");
    std.debug.print("    parseBool(\"TRUE\")           = {}\n", .{parsed_bool});

    const float_str = try stdgo.strconv.formatFloat(allocator, 3.14159265, 'f', 4, 64);
    defer allocator.free(float_str);
    std.debug.print("    formatFloat(3.14159..., 4)  = {s}\n", .{float_str});

    const raw_sentence = "Name:\t\"Go & Zig\"\nStatus:\tReady";
    const quoted_sentence = try stdgo.strconv.quote(allocator, raw_sentence);
    defer allocator.free(quoted_sentence);
    std.debug.print("    quote(raw_sentence)         = {s}\n", .{quoted_sentence});

    const unquoted_sentence = try stdgo.strconv.unquote(allocator, quoted_sentence);
    defer allocator.free(unquoted_sentence);
    std.debug.print("    unquote matches original?   = {}\n", .{std.mem.eql(u8, raw_sentence, unquoted_sentence)});

    // -------------------------------------------------------------
    // 2. unicode.utf16: UTF-16 Surrogate Encoding & Decoding
    // -------------------------------------------------------------
    std.debug.print("\n[2] unicode.utf16 Demo:\n", .{});
    // Musical Symbol G Clef: U+1D11E (requires surrogate pair) and CJK '文' U+6587 (BMP)
    const runes = [_]u32{ 0x1D11E, 0x6587, 'A' };
    const u16_encoded = try stdgo.unicode.utf16.encode(allocator, &runes);
    defer allocator.free(u16_encoded);

    std.debug.print("    Original runes:            [0x{x}, 0x{x}, 0x{x}]\n", .{ runes[0], runes[1], runes[2] });
    std.debug.print("    Encoded UTF-16 code units: [", .{});
    for (u16_encoded, 0..) |cu, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("0x{x}", .{cu});
    }
    std.debug.print("] (length = {d})\n", .{u16_encoded.len});

    const u16_decoded = try stdgo.unicode.utf16.decode(allocator, u16_encoded);
    defer allocator.free(u16_decoded);
    std.debug.print("    Decoded matches original?  = {}\n", .{std.mem.eql(u32, &runes, u16_decoded)});

    // -------------------------------------------------------------
    // 3. html: String Escaping & Entity Unescaping
    // -------------------------------------------------------------
    std.debug.print("\n[3] html Demo:\n", .{});
    const html_input = "<div class=\"user-banner\">stdgo & Zig 0.17 'Rocks'</div>";
    const html_escaped = try stdgo.html.escapeString(allocator, html_input);
    defer allocator.free(html_escaped);
    std.debug.print("    escapeString:   {s}\n", .{html_escaped});

    const entity_input = "Price: &euro;45 &copy; 2026 &#x4E2D;&#x6587; &amp; &quot;Done&quot;";
    const html_unescaped = try stdgo.html.unescapeString(allocator, entity_input);
    defer allocator.free(html_unescaped);
    std.debug.print("    unescapeString: {s}\n", .{html_unescaped});

    // -------------------------------------------------------------
    // 4. image.gif: GIF89a Raster Encoding & Decoding
    // -------------------------------------------------------------
    std.debug.print("\n[4] image.gif Demo:\n", .{});
    // Create an 8x8 colored checkerboard image
    const gif_img = try stdgo.image.RGBAImage.init(allocator, stdgo.image.Rectangle.rect(0, 0, 8, 8));
    defer gif_img.deinit();

    const c_blue = stdgo.image.color.RGBA{ .r = 0, .g = 120, .b = 215, .a = 255 };
    const c_orange = stdgo.image.color.RGBA{ .r = 255, .g = 140, .b = 0, .a = 255 };

    for (0..8) |y| {
        for (0..8) |x| {
            const is_alt = ((x + y) % 2) == 0;
            gif_img.set(@intCast(x), @intCast(y), if (is_alt) c_blue else c_orange);
        }
    }

    const gif_bytes = try stdgo.image.gif.encode(allocator, gif_img);
    defer allocator.free(gif_bytes);

    std.debug.print("    Encoded GIF89a payload size: {d} bytes (magic: {s})\n", .{ gif_bytes.len, gif_bytes[0..6] });

    const decoded_gif = try stdgo.image.gif.decode(allocator, gif_bytes);
    defer decoded_gif.deinit();

    std.debug.print("    Decoded GIF dimensions:     {d}x{d}\n", .{ decoded_gif.rect.dx(), decoded_gif.rect.dy() });
    std.debug.print("    Decoded pixel (0,0) RGB:    ({d}, {d}, {d})\n", .{
        decoded_gif.at(0, 0).r,
        decoded_gif.at(0, 0).g,
        decoded_gif.at(0, 0).b,
    });

    std.debug.print("\n=== Extended Suite Demonstration Completed Successfully ===\n", .{});
}
