//! Package index provides in-memory indexing data structures.
pub const suffixarray = @import("index/suffixarray.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = suffixarray;
}
