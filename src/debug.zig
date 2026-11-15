pub const elf = @import("debug/elf.zig");
pub const macho = @import("debug/macho.zig");
pub const pe = @import("debug/pe.zig");
pub const plan9obj = @import("debug/plan9obj.zig");
pub const dwarf = @import("debug/dwarf.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = elf;
    _ = macho;
    _ = pe;
    _ = plan9obj;
    _ = dwarf;
}
