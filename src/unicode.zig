//! Package unicode provides data and functions to define some properties of Unicode code points.

pub const utf8 = @import("unicode/utf8.zig");

test {
    _ = utf8;
}
