//! Example demonstrating stdgo.net.textproto (MIME Headers and Dot-encoded blocks).
//!
//! Run with: zig build run-textproto

const std = @import("std");
const stdgo = @import("stdgo");
const textproto = stdgo.net.textproto;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo net.textproto Demo ===\n\n", .{});

    // 1. Parsing HTTP/SMTP Status Line & MIME Headers
    const raw_message =
        "POST /api/v1/events HTTP/1.1\r\n" ++
        "host: api.service.internal:8443\r\n" ++
        "content-type: application/json; charset=utf-8\r\n" ++
        "x-trace-id: trace-abc-123\r\n" ++
        "X-Custom-Flag: feature-a\r\n" ++
        "x-custom-flag: feature-b\r\n" ++
        "\r\n";

    var r = bytes.Reader.init(raw_message);
    var tp_reader = textproto.Reader.init(allocator, r.reader());

    // Read initial request line
    const req_line = (try tp_reader.readLine()).?;
    std.debug.print("1. Request Line:\n   -> {s}\n\n", .{req_line});

    // Read MIME Headers with automatic canonical key capitalization
    var headers = try tp_reader.readMIMEHeader();
    defer headers.deinit();

    std.debug.print("2. Parsed MIME Headers (Canonical Keys):\n", .{});
    std.debug.print("   -> Host:         {s}\n", .{headers.get("Host").?});
    std.debug.print("   -> Content-Type: {s}\n", .{headers.get("content-type").?});
    std.debug.print("   -> X-Trace-Id:   {s}\n", .{headers.get("x-trace-id").?});

    const flags = headers.values("x-custom-flag");
    std.debug.print("   -> X-Custom-Flag ({d} values): [", .{flags.len});
    for (flags, 0..) |f, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("'{s}'", .{f});
    }
    std.debug.print("]\n\n", .{});

    // 2. Writing Dot-encoded Mail Body via DotWriter
    std.debug.print("3. Writing and Reading Dot-Encoded Body (SMTP/NNTP Data):\n", .{});
    var mail_buf = bytes.Buffer.init(allocator);
    defer mail_buf.deinit();

    var tp_writer = textproto.Writer.init(mail_buf.writer());
    try tp_writer.writeLine("Subject: Status Report");
    try tp_writer.writeLine("");

    var dot_w = tp_writer.dotWriter(allocator);
    _ = try dot_w.write("First paragraph of email.\n");
    _ = try dot_w.write(".This line begins with a dot (gets escaped to '..')\n");
    _ = try dot_w.write("Regards,\nOperations Team\n");
    try dot_w.close();

    std.debug.print("   Raw dot-encoded transmission wire format:\n{s}\n", .{mail_buf.string()});

    // Read it back with readDotBytes
    var mail_r = bytes.Reader.init(mail_buf.string());
    var mail_tp = textproto.Reader.init(allocator, mail_r.reader());
    var mail_hdr = try mail_tp.readMIMEHeader();
    defer mail_hdr.deinit();

    const decoded_body = try mail_tp.readDotBytes();
    defer allocator.free(decoded_body);

    std.debug.print("   Decoded body through readDotBytes:\n{s}\n", .{decoded_body});

    std.debug.print("=== Demo Complete ===\n", .{});
}
