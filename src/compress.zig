pub const gzip = @import("compress/gzip.zig");
pub const zlib = @import("compress/zlib.zig");
pub const flate = @import("compress/flate.zig");
pub const lzw = @import("compress/lzw.zig");
pub const bzip2 = @import("compress/bzip2.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = gzip;
    _ = zlib;
    _ = flate;
    _ = lzw;
    _ = bzip2;
}
