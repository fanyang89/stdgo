//! Comprehensive demonstration of core Go-standard foundations in Zig 0.17:
//! 1. math.bits (Fast bitwise primitives & 64/128-bit multi-word arithmetic)
//! 2. testing.iotest (Fault injection and chunking stream test readers/writers)
//! 3. mime.quotedprintable (RFC 2045 email encoding & soft line breaks)
//! 4. encoding.ascii85 (Adobe PostScript/PDF 5-to-4 byte base85 with 'z' compression)
//! 5. hash.crc64 (ISO-3309 and ECMA-182 64-bit cyclic redundancy check)
//! 6. text.scanner (UTF-8 lexical token scanner for identifiers, numbers, strings)
//! 7. io.fs (Go 1.16 virtual filesystem abstractions with in-memory MapFS)
//! 8. image.draw & image.png (Porter-Duff alpha compositing and PNG image encode/decode)

const std = @import("std");
const stdgo = @import("stdgo");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo Core Foundations & Media Suite Demonstration ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. math.bits: Multi-word Arithmetic & Fast Bit Twiddling
    // -------------------------------------------------------------
    std.debug.print("[1] math.bits Demo:\n", .{});
    const x: u64 = 0x8000000000000000;
    const y: u64 = 0x000000000000000f;
    std.debug.print("    leadingZeros64(0x{x})  = {d}\n", .{ x, stdgo.math.bits.leadingZeros64(x) });
    std.debug.print("    trailingZeros64(0x{x}) = {d}\n", .{ y, stdgo.math.bits.trailingZeros64(y) });
    std.debug.print("    onesCount64(0x{x})     = {d}\n", .{ y, stdgo.math.bits.onesCount64(y) });

    const add_res = stdgo.math.bits.add64(0xffffffffffffffff, 1, 0);
    std.debug.print("    add64(0xff..ff, 1)        = sum=0x{x}, carry={d}\n", .{ add_res.sum, add_res.carry_out });

    const mul_res = stdgo.math.bits.mul64(1 << 32, 1 << 32);
    std.debug.print("    mul64(2^32, 2^32)         = hi=0x{x}, lo=0x{x} (128-bit 2^64)\n", .{ mul_res.hi, mul_res.lo });

    // -------------------------------------------------------------
    // 2. testing.iotest: Stream Fault Injection & Granularity Control
    // -------------------------------------------------------------
    std.debug.print("\n[2] testing.iotest Demo:\n", .{});
    const test_payload = "ABCDEFGHIJ";
    var fixed_r = std.Io.Reader.fixed(test_payload);
    var one_byte_r = stdgo.testing_pkg.iotest.OneByteReader.init(&fixed_r);
    var obr = one_byte_r.reader();

    var single_byte_buf: [1]u8 = undefined;
    var writer_1b = std.Io.Writer.fixed(&single_byte_buf);
    _ = try obr.stream(&writer_1b, .unlimited);
    std.debug.print("    OneByteReader stream chunk: '{c}' (forces caller loop)\n", .{single_byte_buf[0]});

    var trunc_buf: [32]u8 = undefined;
    var dst_w = std.Io.Writer.fixed(&trunc_buf);
    var trunc_writer = stdgo.testing_pkg.iotest.TruncateWriter.init(&dst_w, 7);
    try trunc_writer.writer().writeAll("Hello, World!");
    std.debug.print("    TruncateWriter(limit=7):    '{s}'\n", .{dst_w.buffered()});

    // -------------------------------------------------------------
    // 3. mime.quotedprintable: RFC 2045 Email Encodings
    // -------------------------------------------------------------
    std.debug.print("\n[3] mime.quotedprintable Demo:\n", .{});
    const email_body = "Price: 100€ = $108 USD.\r\nNext line continues.";
    const qp_encoded = try stdgo.mime.quotedprintable.encodeAlloc(allocator, email_body);
    defer allocator.free(qp_encoded);
    std.debug.print("    Quoted-Printable Encoded:\n      '{s}'\n", .{qp_encoded});

    const qp_decoded = try stdgo.mime.quotedprintable.decodeAlloc(allocator, qp_encoded);
    defer allocator.free(qp_decoded);
    std.debug.print("    Decoded matches original: {any}\n", .{std.mem.eql(u8, email_body, qp_decoded)});

    // -------------------------------------------------------------
    // 4. encoding.ascii85: PostScript & PDF btoa Base85
    // -------------------------------------------------------------
    std.debug.print("\n[4] encoding.ascii85 Demo:\n", .{});
    const quote = "Attack at dawn";
    const a85_enc = try stdgo.encoding.ascii85.encodeAlloc(allocator, quote);
    defer allocator.free(a85_enc);
    std.debug.print("    Encoded '{s}' -> '{s}'\n", .{ quote, a85_enc });

    const zero_chunk = "\x00\x00\x00\x00\x00\x00\x00\x00";
    const a85_zeros = try stdgo.encoding.ascii85.encodeAlloc(allocator, zero_chunk);
    defer allocator.free(a85_zeros);
    std.debug.print("    8 Zero bytes compressed to: '{s}' (special 'z' token)\n", .{a85_zeros});

    // -------------------------------------------------------------
    // 5. hash.crc64: ISO-3309 and ECMA-182 64-bit CRC
    // -------------------------------------------------------------
    std.debug.print("\n[5] hash.crc64 Demo:\n", .{});
    const crc_text = "abcdefghij";
    const iso_val = stdgo.hash.crc64.checksum(crc_text, &stdgo.hash.crc64.iso_table);
    const ecma_val = stdgo.hash.crc64.checksum(crc_text, &stdgo.hash.crc64.ecma_table);
    std.debug.print("    Payload: '{s}'\n", .{crc_text});
    std.debug.print("    CRC-64/ISO:  0x{x:0>16}\n", .{iso_val});
    std.debug.print("    CRC-64/ECMA: 0x{x:0>16}\n", .{ecma_val});

    // -------------------------------------------------------------
    // 6. text.scanner: UTF-8 Tokenizer
    // -------------------------------------------------------------
    std.debug.print("\n[6] text.scanner Demo:\n", .{});
    const code_snippet = "const pi = 3.14; var name = \"stdgo\"; // config";
    var scanner = stdgo.text.scanner.Scanner.init(code_snippet);
    std.debug.print("    Scanning code: '{s}'\n", .{code_snippet});
    while (true) {
        const tok = scanner.scan();
        if (tok == .eof) break;
        if (tok == .ident or tok == .int or tok == .float or tok == .string) {
            std.debug.print("      - Token: {s: <8} Text: {s}\n", .{ @tagName(tok), scanner.tokenText() });
        }
    }

    // -------------------------------------------------------------
    // 7. io.fs: In-Memory Virtual Filesystem (MapFS) & WalkDir
    // -------------------------------------------------------------
    std.debug.print("\n[7] io.fs (MapFS) Demo:\n", .{});
    var vfs = stdgo.io.fs.MapFS.init(allocator);
    defer vfs.deinit();

    try vfs.addFile("etc/config.json", "{\"env\": \"production\"}");
    try vfs.addFile("var/log/app.log", "2026-11-15 INFO system online");
    try vfs.addFile("README.txt", "Virtual FS Demonstration");

    const st = try vfs.stat("etc/config.json");
    std.debug.print("    Stat 'etc/config.json': size={d} bytes, is_dir={any}\n", .{ st.size, st.is_dir });
    const content = try vfs.readFile("etc/config.json");
    std.debug.print("    Read 'etc/config.json': '{s}'\n", .{content});

    std.debug.print("    Walking VFS tree from root (.):\n", .{});
    const Walker = struct {
        fn visit(path: []const u8, d: stdgo.io.fs.DirEntry) anyerror!void {
            std.debug.print("      -> {s: <20} (is_dir: {any})\n", .{ path, d.is_dir });
        }
    };
    try stdgo.io.fs.walkDir(vfs, allocator, ".", Walker.visit);

    // -------------------------------------------------------------
    // 8. image.draw & image.png: Porter-Duff Compositing & PNG Encoding
    // -------------------------------------------------------------
    std.debug.print("\n[8] image.draw & image.png Demo:\n", .{});
    var base_canvas = try stdgo.image.RGBAImage.init(allocator, stdgo.image.Rectangle.rect(0, 0, 8, 8));
    defer base_canvas.deinit();

    // Fill base canvas with blue
    stdgo.image.draw.drawColor(base_canvas, base_canvas.bounds(), stdgo.image.color.RGBA{ .r = 0, .g = 0, .b = 255, .a = 255 }, .Src);

    // Layer semi-transparent yellow over top-left quadrant (Over blend)
    var overlay = try stdgo.image.RGBAImage.init(allocator, stdgo.image.Rectangle.rect(0, 0, 4, 4));
    defer overlay.deinit();
    stdgo.image.draw.drawColor(overlay, overlay.bounds(), stdgo.image.color.RGBA{ .r = 255, .g = 255, .b = 0, .a = 128 }, .Src);
    stdgo.image.draw.draw(base_canvas, stdgo.image.Rectangle.rect(0, 0, 4, 4), overlay, stdgo.image.Point.pt(0, 0), .Over);

    // Encode to PNG bytes
    var png_storage: [2048]u8 = undefined;
    var png_w = std.Io.Writer.fixed(&png_storage);
    try stdgo.image.png.encode(allocator, &png_w, base_canvas);
    const png_data = png_w.buffered();
    std.debug.print("    Generated PNG image: {d} bytes (Header: 0x{x})\n", .{
        png_data.len,
        png_data[0..4],
    });

    // Decode PNG back
    var decoded_png = try stdgo.image.png.decode(allocator, png_data);
    defer decoded_png.deinit();
    std.debug.print("    Decoded PNG verified: {d}x{d} pixels, top-left pixel r={d}, g={d}, b={d}, a={d}\n", .{
        decoded_png.rect.dx(),
        decoded_png.rect.dy(),
        decoded_png.at(0, 0).r,
        decoded_png.at(0, 0).g,
        decoded_png.at(0, 0).b,
        decoded_png.at(0, 0).a,
    });

    std.debug.print("\n=== All Core Foundations & Media Suite Demos Passed! ===\n", .{});
}
