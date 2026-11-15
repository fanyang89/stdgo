pub const hash = @import("hash/hash.zig");
pub const crc32 = @import("hash/crc32.zig");
pub const crc64 = @import("hash/crc64.zig");
pub const adler32 = @import("hash/adler32.zig");
pub const fnv = @import("hash/fnv.zig");

pub const Hash = hash.Hash;
pub const Hash32 = hash.Hash32;
pub const Hash64 = hash.Hash64;

test {
    @import("std").testing.refAllDecls(@This());
    _ = hash;
    _ = crc32;
    _ = crc64;
    _ = adler32;
    _ = fnv;
}
