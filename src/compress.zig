pub const gzip = @import("compress/gzip.zig");
pub const zlib = @import("compress/zlib.zig");
pub const flate = @import("compress/flate.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = gzip;
    _ = zlib;
    _ = flate;
}
