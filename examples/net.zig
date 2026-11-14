//! Example demonstrating stdgo net package:
//! 1. IP address parsing, private / loopback checks
//! 2. CIDR subnet mask calculation & IPNet.contains
//! 3. splitHostPort & joinHostPort

const std = @import("std");
const stdgo = @import("stdgo");
const net = stdgo.net;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: net (IP, CIDR, HostPort) Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. IP Parsing and Classifications
    // -------------------------------------------------------------
    std.debug.print("1. net.parseIp:\n", .{});

    const ip_list = [_][]const u8{
        "127.0.0.1",
        "192.168.1.100",
        "10.0.4.1",
        "8.8.8.8",
        "::1",
        "2001:db8::1",
    };

    for (ip_list) |s| {
        if (net.parseIp(s)) |addr| {
            std.debug.print("   IP: {s: <16} -> loopback: {}, private: {}\n", .{
                s,
                addr.isLoopback(),
                addr.isPrivate(),
            });
        }
    }

    // -------------------------------------------------------------
    // 2. CIDR Subnet and Membership
    // -------------------------------------------------------------
    std.debug.print("\n2. net.parseCidr and IPNet.contains:\n", .{});

    const subnet_cidr = "10.244.0.0/16";
    const cidr_res = try net.parseCidr(subnet_cidr);
    std.debug.print("   Subnet: {s}, Network base: {}\n", .{ subnet_cidr, cidr_res.ipnet.network() });

    const test_ips = [_][]const u8{
        "10.244.15.99",
        "10.244.254.1",
        "10.245.0.1",
        "192.168.1.1",
    };

    for (test_ips) |tip| {
        if (net.parseIp(tip)) |addr| {
            const inside = cidr_res.ipnet.contains(addr);
            std.debug.print("   Contains {s: <14}? {}\n", .{ tip, inside });
        }
    }

    // -------------------------------------------------------------
    // 3. splitHostPort & joinHostPort
    // -------------------------------------------------------------
    std.debug.print("\n3. net.splitHostPort & net.joinHostPort:\n", .{});

    const addresses = [_][]const u8{
        "127.0.0.1:8080",
        "[::1]:9090",
        "api.example.com:443",
    };

    for (addresses) |addr_str| {
        const hp = try net.splitHostPort(addr_str);
        std.debug.print("   split('{s}') -> host: '{s}', port: '{s}'\n", .{ addr_str, hp.host, hp.port });

        const rejoined = try net.joinHostPort(gpa, hp.host, hp.port);
        defer gpa.free(rejoined);
        std.debug.print("   rejoined: '{s}'\n", .{rejoined});
    }

    std.debug.print("\nnet example finished successfully.\n", .{});
}
