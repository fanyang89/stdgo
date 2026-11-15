//! Package testing provides support for automated testing of Go/Zig packages.
pub const quick = @import("testing/quick.zig");
pub const iotest = @import("testing/iotest.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = quick;
    _ = iotest;
}
