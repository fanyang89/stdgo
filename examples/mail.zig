const std = @import("std");
const stdgo = @import("stdgo");
const mail = stdgo.net.mail;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("=== stdgo.net.mail RFC 5322 Parsing Demo ===\n\n");

    // 1. Parsing single addresses
    try stdout.writeAll("1. Parsing single email addresses (parseAddress):\n");
    const test_addresses = [_][]const u8{
        "alice@example.com",
        "Alice Smith <alice@example.com>",
        "\"Smith, Alice\" <alice@example.com>",
        "support@company.org (Customer Support)",
    };

    for (test_addresses) |raw| {
        var addr = try mail.parseAddress(allocator, raw);
        defer addr.deinit(allocator);

        const formatted = try addr.string(allocator);
        defer allocator.free(formatted);

        try stdout.print("   Raw:       {s}\n", .{raw});
        try stdout.print("   Name:      '{s}'\n", .{addr.name});
        try stdout.print("   Address:   '{s}'\n", .{addr.address});
        try stdout.print("   Formatted: {s}\n\n", .{formatted});
    }

    // 2. Parsing address list
    try stdout.writeAll("2. Parsing comma-separated address list (parseAddressList):\n");
    const raw_list = "\"Smith, Alice\" <alice@example.com>, Bob <bob@example.com>, carol@example.com";
    const addrs = try mail.parseAddressList(allocator, raw_list);
    defer {
        for (addrs) |*a| a.deinit(allocator);
        allocator.free(addrs);
    }

    try stdout.print("   Input: {s}\n", .{raw_list});
    try stdout.print("   Parsed {d} addresses:\n", .{addrs.len});
    for (addrs, 0..) |a, i| {
        try stdout.print("     [{d}] Name: '{s}', Address: '{s}'\n", .{ i + 1, a.name, a.address });
    }

    // 3. Reading and parsing an RFC 5322 email message with headers and body
    try stdout.writeAll("\n3. Reading full RFC 5322 Email Message (readMessage):\n");
    const raw_email =
        "From: \"Alice Smith\" <alice@example.com>\r\n" ++
        "To: Bob <bob@example.com>\r\n" ++
        "Subject: Weekly Project Status\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "\r\n" ++
        "Hi Bob,\r\n\r\n" ++
        "All 30 modular examples in stdgo are compiling and passing.\r\n" ++
        "Have a great weekend!\r\n";

    var r = stdgo.bytes.Reader.init(raw_email);
    var msg = try mail.readMessage(allocator, r.reader());
    defer msg.deinit();

    try stdout.print("   From:         {s}\n", .{msg.header.get("From").?});
    try stdout.print("   To:           {s}\n", .{msg.header.get("To").?});
    try stdout.print("   Subject:      {s}\n", .{msg.header.get("Subject").?});
    try stdout.print("   Content-Type: {s}\n", .{msg.header.get("Content-Type").?});

    var body_buf: [256]u8 = undefined;
    const n = try msg.body.readSliceShort(&body_buf);
    try stdout.print("\n   Message Body:\n---\n{s}---\n", .{body_buf[0..n]});

    try stdout.writeAll("Mail demo completed successfully!\n");
    try stdout.flush();
}
