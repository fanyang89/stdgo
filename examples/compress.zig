//! Example demonstrating stdgo compress package:
//! 1. compress.gzip: writing Gzip file with header, reading & CRC32 verification
//! 2. compress.zlib: RFC 1950 zlib compression & decompression with Adler-32
//! 3. compress.flate: RFC 1951 Raw Deflate bitstream compression & decompression

const std = @import("std");
const stdgo = @import("stdgo");
const gzip = stdgo.compress.gzip;
const zlib = stdgo.compress.zlib;
const flate = stdgo.compress.flate;
const bytes = stdgo.bytes;
const io = stdgo.io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: compress (gzip, zlib, flate) Example ===\n\n", .{});

    const original_text = "stdgo brings Go standard library ergonomics and compression to Zig 0.17!";

    // -------------------------------------------------------------
    // 1. compress.gzip
    // -------------------------------------------------------------
    std.debug.print("1. compress.gzip:\n", .{});
    var gz_buf = bytes.Buffer.init(gpa);
    defer gz_buf.deinit();

    var gzip_w = try gzip.Writer.init(gpa, gz_buf.writer(), .{
        .name = "gopher_doc.txt",
        .mod_time = 1700000000,
        .os = 255,
    });
    _ = try gzip_w.write(original_text);
    try gzip_w.close();

    var gz_reader_src = bytes.Reader.init(gz_buf.bytes());
    var gzip_r = try gzip.Reader.init(gpa, gz_reader_src.reader());
    std.debug.print("   Header Name: '{s}', ModTime: {d}\n", .{ gzip_r.header.name, gzip_r.header.mod_time });

    const gz_decompressed = try gzip_r.readAllAlloc(gpa);
    defer gpa.free(gz_decompressed);
    std.debug.print("   Decompressed: '{s}' (verified: {})\n", .{
        gz_decompressed,
        std.mem.eql(u8, original_text, gz_decompressed),
    });

    // -------------------------------------------------------------
    // 2. compress.zlib
    // -------------------------------------------------------------
    std.debug.print("\n2. compress.zlib (RFC 1950 with Adler-32):\n", .{});
    var zlib_buf = bytes.Buffer.init(gpa);
    defer zlib_buf.deinit();

    var zw = try zlib.newWriter(gpa, zlib_buf.writer());
    defer zw.deinit();
    try zw.writer().writeAll(original_text);
    try zw.close();

    std.debug.print("   Compressed size: {d} bytes (Header: 0x{x})\n", .{ zlib_buf.len(), zlib_buf.bytes()[0] });

    var zlib_reader_src = bytes.Reader.init(zlib_buf.bytes());
    var zr = try zlib.newReader(gpa, zlib_reader_src.reader());
    defer zr.deinit();

    var zlib_out = bytes.Buffer.init(gpa);
    defer zlib_out.deinit();
    _ = try io.copy(zlib_out.writer(), zr.reader());
    std.debug.print("   Decompressed: '{s}' (matches: {})\n", .{
        zlib_out.string(),
        std.mem.eql(u8, original_text, zlib_out.string()),
    });

    // -------------------------------------------------------------
    // 3. compress.flate
    // -------------------------------------------------------------
    std.debug.print("\n3. compress.flate (RFC 1951 Raw Deflate):\n", .{});
    var flate_buf = bytes.Buffer.init(gpa);
    defer flate_buf.deinit();

    var fw = try flate.newWriter(gpa, flate_buf.writer(), flate.BestSpeed);
    defer fw.deinit();
    try fw.writer().writeAll(original_text);
    try fw.close();

    std.debug.print("   Raw Deflate size: {d} bytes\n", .{flate_buf.len()});

    var flate_reader_src = bytes.Reader.init(flate_buf.bytes());
    var fr = try flate.newReader(gpa, flate_reader_src.reader());
    defer fr.deinit();

    var flate_out = bytes.Buffer.init(gpa);
    defer flate_out.deinit();
    _ = try io.copy(flate_out.writer(), fr.reader());
    std.debug.print("   Decompressed: '{s}' (matches: {})\n", .{
        flate_out.string(),
        std.mem.eql(u8, original_text, flate_out.string()),
    });

    std.debug.print("\ncompress demo completed successfully!\n", .{});
}
