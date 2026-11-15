pub const tabwriter = @import("text/tabwriter.zig");
pub const template = @import("text/template.zig");
pub const scanner = @import("text/scanner.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = tabwriter;
    _ = template;
    _ = scanner;
}
