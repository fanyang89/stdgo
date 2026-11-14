pub const url = @import("net/url.zig");
pub const http = @import("net/http.zig");
pub const ip = @import("net/ip.zig");
pub const hostport = @import("net/hostport.zig");

// Direct aliases matching Go net package
pub const IP = ip.IP;
pub const IPMask = ip.IPMask;
pub const IPNet = ip.IPNet;
pub const parseIp = ip.parseIp;
pub const parseCidr = ip.parseCidr;
pub const cidrMask = ip.cidrMask;
pub const ipv4Mask = ip.ipv4Mask;

pub const splitHostPort = hostport.splitHostPort;
pub const joinHostPort = hostport.joinHostPort;
pub const HostPort = hostport.HostPort;

test {
    @import("std").testing.refAllDecls(@This());
    _ = url;
    _ = http;
    _ = ip;
    _ = hostport;
}
