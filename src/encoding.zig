pub const binary = @import("encoding/binary.zig");
pub const csv = @import("encoding/csv.zig");
pub const base64 = @import("encoding/base64.zig");
pub const base32 = @import("encoding/base32.zig");
pub const ascii85 = @import("encoding/ascii85.zig");
pub const hex = @import("encoding/hex.zig");
pub const json = @import("encoding/json.zig");
pub const xml = @import("encoding/xml.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = binary;
    _ = csv;
    _ = base64;
    _ = base32;
    _ = ascii85;
    _ = hex;
    _ = json;
    _ = xml;
}
