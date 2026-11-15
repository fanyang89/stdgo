//! Example demonstrating stdgo:
//! 1. net.listenUDP & net.dialUDP (UDP datagram PacketConn)
//! 2. net.dns RFC 1035 wire protocol & Resolver
//! 3. net.smtp RFC 5321 Client & sendMail with PLAIN authentication

const std = @import("std");
const stdgo = @import("stdgo");
const net = stdgo.net;
const smtp = net.smtp;
const dns = net.dns;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    std.debug.print("=== stdgo: UDP, DNS (RFC 1035), and SMTP (RFC 5321) Demo ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. UDP Datagram (PacketConn & UDPConn)
    // -------------------------------------------------------------
    std.debug.print("--- 1. UDP Datagram Communication (PacketConn) ---\n", .{});

    const server_uc = try net.listenUDP(gpa, io, "udp", "127.0.0.1:0");
    defer server_uc.close();
    const s_port = server_uc.port();

    var s_addr_buf: [32]u8 = undefined;
    const s_addr_str = try std.fmt.bufPrint(&s_addr_buf, "127.0.0.1:{d}", .{s_port});

    const client_uc = try net.dialUDP(gpa, io, "udp", null, s_addr_str);
    defer client_uc.close();

    _ = try client_uc.write("PING_DATAGRAM_PACKET");

    var recv_buf: [128]u8 = undefined;
    const from_res = try server_uc.readFrom(&recv_buf);
    std.debug.print("UDP Server received {d} bytes from {}: '{s}'\n", .{
        from_res.n,
        from_res.addr,
        recv_buf[0..from_res.n],
    });

    _ = try server_uc.writeTo("PONG_DATAGRAM_REPLY", from_res.addr);

    var client_recv: [128]u8 = undefined;
    const cn = try client_uc.read(&client_recv);
    std.debug.print("UDP Client received: '{s}'\n", .{client_recv[0..cn]});

    // -------------------------------------------------------------
    // 2. DNS RFC 1035 Wire Protocol Encoding & Mock Resolver
    // -------------------------------------------------------------
    std.debug.print("\n--- 2. RFC 1035 DNS Protocol & Resolver ---\n", .{});

    var q_packet: [512]u8 = undefined;
    const q_len = try dns.buildQuery(0x1234, "mail.example.org", .MX, &q_packet);
    std.debug.print("Built DNS MX Query for 'mail.example.org', packet size: {d} bytes\n", .{q_len});

    // Spin up a mock authoritative DNS server
    const mock_dns = try net.listenUDP(gpa, io, "udp", "127.0.0.1:0");
    defer mock_dns.close();
    const dns_port = mock_dns.port();

    const MockDnsWorker = struct {
        fn run(s: *net.UDPConn) void {
            var q_count: usize = 0;
            while (q_count < 2) : (q_count += 1) {
                var buf: [512]u8 = undefined;
                const r = s.readFrom(&buf) catch return;
                if (r.n < 12) return;

                const qid = std.mem.readInt(u16, buf[0..2], .big);

                var resp: [512]u8 = undefined;
                std.mem.writeInt(u16, resp[0..2], qid, .big);
                std.mem.writeInt(u16, resp[2..4], 0x8180, .big); // QR=1, RA=1
                std.mem.writeInt(u16, resp[4..6], 1, .big); // QDCOUNT=1
                std.mem.writeInt(u16, resp[6..8], 1, .big); // ANCOUNT=1
                std.mem.writeInt(u16, resp[8..10], 0, .big);
                std.mem.writeInt(u16, resp[10..12], 0, .big);

                const q_part = buf[12..r.n];
                @memcpy(resp[12 .. 12 + q_part.len], q_part);
                var pos = 12 + q_part.len;

                // Answer: Pointer to QNAME (0xC00C)
                std.mem.writeInt(u16, resp[pos..][0..2], 0xC00C, .big);
                pos += 2;
                std.mem.writeInt(u16, resp[pos..][0..2], 1, .big); // TYPE A
                pos += 2;
                std.mem.writeInt(u16, resp[pos..][0..2], 1, .big); // CLASS IN
                pos += 2;
                std.mem.writeInt(u32, resp[pos..][0..4], 3600, .big); // TTL
                pos += 4;
                std.mem.writeInt(u16, resp[pos..][0..2], 4, .big); // RDLENGTH 4
                pos += 2;
                @memcpy(resp[pos..][0..4], &[_]u8{ 104, 21, 56, 99 }); // IP 104.21.56.99
                pos += 4;

                _ = s.writeTo(resp[0..pos], r.addr) catch return;
            }
        }
    };

    const dns_thread = try std.Thread.spawn(.{}, MockDnsWorker.run, .{mock_dns});
    defer dns_thread.join();

    var ns_buf: [32]u8 = undefined;
    const ns_str = try std.fmt.bufPrint(&ns_buf, "127.0.0.1:{d}", .{dns_port});

    const resolver = net.Resolver{
        .nameserver = ns_str,
    };

    const resolved_hosts = try resolver.lookupHost(gpa, io, "mail.example.org");
    defer {
        for (resolved_hosts) |h| gpa.free(h);
        gpa.free(resolved_hosts);
    }

    for (resolved_hosts) |ip_str| {
        std.debug.print("DNS resolved 'mail.example.org' -> {s}\n", .{ip_str});
    }

    // -------------------------------------------------------------
    // 3. SMTP RFC 5321 Email Sending with PLAIN Authentication
    // -------------------------------------------------------------
    std.debug.print("\n--- 3. RFC 5321 SMTP Client & sendMail ---\n", .{});

    var smtp_server = try net.listen(gpa, io, "tcp", "127.0.0.1:0");
    defer smtp_server.close();
    const smtp_port = smtp_server.port().?;

    const MockSmtpWorker = struct {
        fn run(l: net.Listener) void {
            const sc = l.accept() catch return;
            defer sc.close();

            _ = sc.write("220 smtp.stdgo.internal ESMTP Service Ready\r\n") catch return;

            var buf: [512]u8 = undefined;
            // EHLO
            var n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("250-smtp.stdgo.internal\r\n250-AUTH PLAIN\r\n250 8BITMIME\r\n") catch return;

            // AUTH PLAIN
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("235 2.7.0 Authentication accepted\r\n") catch return;

            // MAIL FROM
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("250 2.1.0 Sender OK\r\n") catch return;

            // RCPT TO
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("250 2.1.5 Recipient OK\r\n") catch return;

            // DATA
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("354 Start mail input; end with <CRLF>.<CRLF>\r\n") catch return;

            // Mail body
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("250 2.0.0 OK: message queued 10042\r\n") catch return;

            // QUIT
            n = sc.read(&buf) catch return;
            if (n == 0) return;
            _ = sc.write("221 2.0.0 Bye\r\n") catch return;
        }
    };

    const smtp_thread = try std.Thread.spawn(.{}, MockSmtpWorker.run, .{smtp_server});
    defer smtp_thread.join();

    var smtp_addr_buf: [32]u8 = undefined;
    const smtp_addr_str = try std.fmt.bufPrint(&smtp_addr_buf, "127.0.0.1:{d}", .{smtp_port});

    const auth = try smtp.plainAuth(gpa, "", "gopher@stdgo.dev", "supersecret", "127.0.0.1");
    defer auth.deinit();

    const to_recipients = [_][]const u8{"team@company.internal"};
    const message_content =
        "From: gopher@stdgo.dev\r\n" ++
        "To: team@company.internal\r\n" ++
        "Subject: SMTP, UDP, and DNS are live in Zig 0.17!\r\n" ++
        "\r\n" ++
        "All Go net features are now completely supported in stdgo.\r\n";

    try smtp.sendMail(
        gpa,
        io,
        smtp_addr_str,
        auth,
        "gopher@stdgo.dev",
        &to_recipients,
        message_content,
    );

    std.debug.print("Successfully sent RFC 5321 email message via sendMail!\n", .{});
    std.debug.print("\n=== Demo Complete ===\n", .{});
}
