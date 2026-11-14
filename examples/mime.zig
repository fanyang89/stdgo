const std = @import("std");
const stdgo = @import("stdgo");
const mime = stdgo.mime;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("=== stdgo.mime Media Type & Extension Demo ===\n\n");

    // 1. Parsing Content-Type headers
    try stdout.writeAll("1. Parsing Content-Type and Content-Disposition:\n");
    const raw1 = "text/html; charset=utf-8; boundary=something";
    var mt1 = try mime.parseMediaType(allocator, raw1);
    defer mt1.deinit(allocator);

    try stdout.print("   Raw:        {s}\n", .{raw1});
    try stdout.print("   Media Type: {s}\n", .{mt1.media_type});
    try stdout.print("   Charset:    {s}\n", .{mt1.params.get("charset").?});
    try stdout.print("   Boundary:   {s}\n\n", .{mt1.params.get("boundary").?});

    const raw2 = "form-data; name=\"upload_file\"; filename=\"user_report.pdf\"";
    var mt2 = try mime.parseMediaType(allocator, raw2);
    defer mt2.deinit(allocator);

    try stdout.print("   Raw:        {s}\n", .{raw2});
    try stdout.print("   Media Type: {s}\n", .{mt2.media_type});
    try stdout.print("   Field Name: {s}\n", .{mt2.params.get("name").?});
    try stdout.print("   Filename:   {s}\n\n", .{mt2.params.get("filename").?});

    // 2. Formatting media type with parameters
    try stdout.writeAll("2. Formatting media type:\n");
    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("charset", "utf-8");
    try params.put("title", "Hello World");

    const formatted = try mime.formatMediaType(allocator, "application/json", &params);
    defer allocator.free(formatted);
    try stdout.print("   Formatted: {s}\n\n", .{formatted});

    // 3. Extension to MIME type lookup
    try stdout.writeAll("3. Extension to MIME type lookup (typeByExtension):\n");
    const sample_exts = [_][]const u8{ ".json", ".png", ".html", ".wasm", ".pdf", ".mp4", "jpg" };
    for (sample_exts) |ext| {
        const typ = mime.typeByExtension(ext) orelse "unknown";
        try stdout.print("   {s: <8} -> {s}\n", .{ ext, typ });
    }

    // 4. Reverse lookup: extensions for a MIME type
    try stdout.writeAll("\n4. Extensions for 'image/jpeg':\n");
    const exts = try mime.extensionsByType(allocator, "image/jpeg");
    defer allocator.free(exts);
    for (exts) |ext| {
        try stdout.print("   {s}\n", .{ext});
    }

    try stdout.writeAll("\nMIME demo completed successfully!\n");
    try stdout.flush();
}
