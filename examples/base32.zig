//! Example demonstrating stdgo.encoding.base32 (RFC 4648 Base32).
//!
//! Run with: zig build run-base32

const std = @import("std");
const stdgo = @import("stdgo");
const base32 = stdgo.encoding.base32;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo encoding/base32 Demo ===\n\n", .{});

    // 1. Standard RFC 4648 Base32 Encoding
    const sample = "Zig 0.17 stdgo";
    const encoded = try base32.std_encoding.encodeToString(allocator, sample);
    defer allocator.free(encoded);

    std.debug.print("1. Standard Base32 (StdEncoding):\n", .{});
    std.debug.print("   Plain:   '{s}'\n", .{sample});
    std.debug.print("   Encoded: '{s}'\n\n", .{encoded});

    // 2. Decoding back
    const decoded = try base32.std_encoding.decodeString(allocator, encoded);
    defer allocator.free(decoded);
    std.debug.print("2. Decoded back:\n   -> '{s}'\n\n", .{decoded});

    // 3. Extended Hex Alphabet (HexEncoding)
    const hex_encoded = try base32.hex_encoding.encodeToString(allocator, sample);
    defer allocator.free(hex_encoded);
    std.debug.print("3. Extended Hex Base32 (HexEncoding):\n   -> '{s}'\n\n", .{hex_encoded});

    // 4. TOTP Secret Key formatting (unpadded base32)
    const raw_secret = "JBSWY3DPEHPK3PXP"; // Common Google Authenticator test secret
    const secret_bytes = try base32.std_encoding.noPadding().decodeString(allocator, raw_secret);
    defer allocator.free(secret_bytes);

    const hex_str = try stdgo.encoding.hex.encodeToString(allocator, secret_bytes);
    defer allocator.free(hex_str);

    std.debug.print("4. Unpadded Base32 (TOTP Secret key decoding):\n", .{});
    std.debug.print("   TOTP Key: '{s}' -> Decoded Length: {d} bytes (0x{s})\n\n", .{
        raw_secret,
        secret_bytes.len,
        hex_str,
    });

    std.debug.print("=== Demo Complete ===\n", .{});
}
