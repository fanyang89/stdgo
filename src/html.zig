pub const template = @import("html/template.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = template;
}
