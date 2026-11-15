const std = @import("std");
const stdgo = @import("stdgo");
const big = stdgo.math.big;
const xml = stdgo.encoding.xml;
const image = stdgo.image;
const color = stdgo.image.color;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo Data & Media Suite Demo ===\n\n", .{});

    // ---------------------------------------------------------
    // 1. math/big: High-Precision Arbitrary Integer Arithmetic
    // ---------------------------------------------------------
    std.debug.print("[1] math/big Demo:\n", .{});

    // 2^128 as a large number
    var a = try big.newInt(allocator);
    defer a.deinit();
    _ = try a.setString("340282366920938463463374607431768211456", 10);

    var b = try big.fromInt64(allocator, 123456789);
    defer b.deinit();

    var prod = try big.newInt(allocator);
    defer prod.deinit();
    _ = try prod.mul(&a, &b);

    const prod_str = try prod.string(allocator);
    defer allocator.free(prod_str);
    std.debug.print("    2^128 * 123456789 = {s}\n", .{prod_str});

    // Modular exponentiation: 123456^789 mod 1000000007
    var base = try big.fromInt64(allocator, 123456);
    defer base.deinit();

    var exp_val = try big.fromInt64(allocator, 789);
    defer exp_val.deinit();

    var mod_val = try big.fromInt64(allocator, 1000000007);
    defer mod_val.deinit();

    var mod_pow_res = try big.newInt(allocator);
    defer mod_pow_res.deinit();
    _ = try mod_pow_res.exp(&base, &exp_val, &mod_val);

    std.debug.print("    123456^789 mod 1000000007 = {?d}\n", .{mod_pow_res.int64()});

    // Hex and Binary parsing
    var hex_val = try big.fromString(allocator, "0xCAFE_BABE", 0);
    defer hex_val.deinit();
    std.debug.print("    Parsed '0xCAFE_BABE' uint64: 0x{x} ({d})\n", .{ hex_val.uint64().?, hex_val.uint64().? });

    // ---------------------------------------------------------
    // 2. encoding/xml: Streaming XML Decoding & Encoding
    // ---------------------------------------------------------
    std.debug.print("\n[2] encoding/xml Demo:\n", .{});

    const sample_xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<library name="StdGo Books &amp; Papers">
        \\    <book id="b1" rating="5">
        \\        <title>The Go Programming Language</title>
        \\        <author>Alan Donovan &amp; Brian Kernighan</author>
        \\    </book>
        \\    <book id="b2" rating="5">
        \\        <title>Programming in Zig</title>
        \\        <author>TigerStyle Enthusiasts</author>
        \\    </book>
        \\    <shelf location="Row 4" empty="false"/>
        \\</library>
    ;

    var xml_reader = bytes.Reader.init(sample_xml);
    var dec = xml.Decoder.init(allocator, xml_reader.reader());
    defer dec.deinit();

    while (try dec.token()) |tok| {
        switch (tok) {
            .proc_inst => |pi| {
                std.debug.print("    [ProcInst] target={s}, inst={s}\n", .{ pi.target, pi.inst });
            },
            .start_element => |se| {
                std.debug.print("    [Start] <{s}", .{se.name.local});
                for (se.attr) |at| {
                    std.debug.print(" {s}=\"{s}\"", .{ at.name.local, at.value });
                }
                std.debug.print(">\n", .{});
            },
            .end_element => |ee| {
                std.debug.print("    [End] </{s}>\n", .{ee.name.local});
            },
            .char_data => |cd| {
                const trimmed = std.mem.trim(u8, cd, " \t\r\n");
                if (trimmed.len > 0) {
                    std.debug.print("        [Text] {s}\n", .{trimmed});
                }
            },
            else => {},
        }
    }

    // Encoder demo
    var xml_out_buf = bytes.Buffer.init(allocator);
    defer xml_out_buf.deinit();
    var enc = xml.Encoder.init(allocator, xml_out_buf.writer());

    try enc.encodeToken(xml.Token{
        .start_element = .{
            .name = .{ .local = "response" },
            .attr = &.{
                .{ .name = .{ .local = "status" }, .value = "success" },
            },
        },
    });
    try enc.encodeToken(xml.Token{ .char_data = "Data generated with <XML> & 100% precision" });
    try enc.encodeToken(xml.Token{ .end_element = .{ .name = .{ .local = "response" } } });
    try enc.flush();

    std.debug.print("    Encoded XML: {s}\n", .{xml_out_buf.string()});

    // ---------------------------------------------------------
    // 3. image & image/color: 2D Raster Image and Geometry
    // ---------------------------------------------------------
    std.debug.print("\n[3] image & image/color Demo:\n", .{});

    const canvas_rect = image.rect(0, 0, 8, 8);
    var canvas = try image.RGBAImage.init(allocator, canvas_rect);
    defer canvas.deinit();

    // Fill background with white
    const white = color.RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 };
    var y: i32 = 0;
    while (y < 8) : (y += 1) {
        var x: i32 = 0;
        while (x < 8) : (x += 1) {
            canvas.set(x, y, white);
        }
    }

    // Draw a red diagonal cross
    const red = color.RGBA{ .r = 255, .g = 0, .b = 0, .a = 255 };
    var i: i32 = 0;
    while (i < 8) : (i += 1) {
        canvas.set(i, i, red);
        canvas.set(7 - i, i, red);
    }

    // Inspect subImage
    var sub = canvas.subImage(image.rect(0, 0, 4, 4));
    std.debug.print("    Canvas Size: {d}x{d}, SubImage Size: {d}x{d}\n", .{
        canvas.bounds().dx(),
        canvas.bounds().dy(),
        sub.rect.dx(),
        sub.rect.dy(),
    });

    const center_pixel = canvas.at(3, 3);
    std.debug.print("    Pixel (3, 3) RGBA: ({d}, {d}, {d}, {d})\n", .{
        center_pixel.r,
        center_pixel.g,
        center_pixel.b,
        center_pixel.a,
    });

    std.debug.print("\n=== All Data & Media Suite Demos Completed Successfully! ===\n", .{});
}
