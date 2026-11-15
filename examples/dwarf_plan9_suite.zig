const std = @import("std");
const stdgo = @import("stdgo");
const plan9obj = stdgo.debug.plan9obj;
const dwarf = stdgo.debug.dwarf;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo debug/plan9obj & debug/dwarf Demonstration ===\n\n", .{});

    // 1. Plan 9 a.out object parsing
    std.debug.print("1. Parsing Plan 9 a.out Executable:\n", .{});
    var plan9_buf = std.ArrayList(u8).empty;
    defer plan9_buf.deinit(allocator);

    var hdr: [40]u8 = undefined;
    @memset(&hdr, 0);
    std.mem.writeInt(u32, hdr[0..4], plan9obj.MagicAMD64, .big);
    std.mem.writeInt(u32, hdr[4..8], 0x100, .big); // text: 256 bytes
    std.mem.writeInt(u32, hdr[8..12], 0x40, .big); // data: 64 bytes
    std.mem.writeInt(u32, hdr[12..16], 0x200, .big); // bss: 512 bytes

    // Build synthetic Plan 9 symbols
    var syms_raw = std.ArrayList(u8).empty;
    defer syms_raw.deinit(allocator);

    // Function 'T' main at 0x200020
    try syms_raw.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x20 });
    try syms_raw.append(allocator, 'T');
    try syms_raw.appendSlice(allocator, "main\x00");

    // File component 'f' index 1: "pkg"
    try syms_raw.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 });
    try syms_raw.append(allocator, 'f');
    try syms_raw.appendSlice(allocator, "pkg\x00");

    // File component 'f' index 2: "app.go"
    try syms_raw.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 });
    try syms_raw.append(allocator, 'f');
    try syms_raw.appendSlice(allocator, "app.go\x00");

    // File path 'z': index 1 / index 2 => "pkg/app.go"
    try syms_raw.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try syms_raw.append(allocator, 'z');
    try syms_raw.append(allocator, 0x00);
    try syms_raw.appendSlice(allocator, &[_]u8{ 0x00, 0x01, 0x00, 0x02, 0x00, 0x00 });

    std.mem.writeInt(u32, hdr[16..20], @intCast(syms_raw.items.len), .big); // syms
    std.mem.writeInt(u32, hdr[20..24], 0x20, .big); // entry lower
    std.mem.writeInt(u32, hdr[24..28], 0, .big); // spsz
    std.mem.writeInt(u32, hdr[28..32], 0, .big); // pcsz
    std.mem.writeInt(u64, hdr[32..40], 0x200020, .big); // 64-bit entry

    try plan9_buf.appendSlice(allocator, &hdr);
    const text_payload = try allocator.alloc(u8, 0x100);
    @memset(text_payload, 0x90); // NOPs
    try plan9_buf.appendSlice(allocator, text_payload);

    const data_payload = try allocator.alloc(u8, 0x40);
    @memset(data_payload, 0x00);
    try plan9_buf.appendSlice(allocator, data_payload);

    try plan9_buf.appendSlice(allocator, syms_raw.items);

    var p9_file = try plan9obj.File.parse(allocator, plan9_buf.items);
    defer p9_file.deinit();

    std.debug.print("  Architecture: AMD64 (Magic: 0x{x})\n", .{p9_file.header.magic});
    std.debug.print("  Entry point:  0x{x}\n", .{p9_file.header.entry});
    std.debug.print("  Load address: 0x{x}\n", .{p9_file.header.load_address});
    std.debug.print("  Sections ({d}):\n", .{p9_file.sections.len});
    for (p9_file.sections) |s| {
        std.debug.print("    - {s: <6} offset=0x{x:0>4} size={d} bytes\n", .{
            s.header.name,
            s.header.offset,
            s.header.size,
        });
    }

    const p9_syms = try p9_file.symbols(allocator);
    defer {
        for (p9_syms) |*s| s.deinit(allocator);
        allocator.free(p9_syms);
    }
    std.debug.print("  Symbols ({d}):\n", .{p9_syms.len});
    for (p9_syms) |s| {
        std.debug.print("    - type='{c}' value=0x{x:0>8} name='{s}'\n", .{
            s.typ,
            s.value,
            s.name,
        });
    }

    // 2. DWARF Debugging Information Entries (DIEs) parsing
    std.debug.print("\n2. Parsing DWARF Debug Information:\n", .{});

    // String table
    var d_str = std.ArrayList(u8).empty;
    defer d_str.deinit(allocator);
    try d_str.appendSlice(allocator, "calculator.zig\x00");
    try d_str.appendSlice(allocator, "calculate_sum\x00");

    // Abbreviation table
    var d_abbrev = std.ArrayList(u8).empty;
    defer d_abbrev.deinit(allocator);

    // Abbrev 1: TagCompileUnit with children
    try d_abbrev.append(allocator, 1);
    try d_abbrev.append(allocator, dwarf.TagCompileUnit);
    try d_abbrev.append(allocator, 1); // has children
    try d_abbrev.append(allocator, dwarf.AttrName);
    try d_abbrev.append(allocator, dwarf.FormStrp);
    try d_abbrev.append(allocator, dwarf.AttrLowpc);
    try d_abbrev.append(allocator, dwarf.FormAddr);
    try d_abbrev.append(allocator, dwarf.AttrHighpc);
    try d_abbrev.append(allocator, dwarf.FormData4);
    try d_abbrev.appendSlice(allocator, &[_]u8{ 0, 0 });

    // Abbrev 2: TagSubprogram without children
    try d_abbrev.append(allocator, 2);
    try d_abbrev.append(allocator, dwarf.TagSubprogram);
    try d_abbrev.append(allocator, 0); // no children
    try d_abbrev.append(allocator, dwarf.AttrName);
    try d_abbrev.append(allocator, dwarf.FormStrp);
    try d_abbrev.append(allocator, dwarf.AttrLowpc);
    try d_abbrev.append(allocator, dwarf.FormAddr);
    try d_abbrev.appendSlice(allocator, &[_]u8{ 0, 0 });
    try d_abbrev.append(allocator, 0); // table end

    // Info payload
    var d_body = std.ArrayList(u8).empty;
    defer d_body.deinit(allocator);

    // DIE 1: CompileUnit ("calculator.zig", lowpc=0x401000, highpc=0x350)
    try d_body.append(allocator, 1);
    try d_body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // offset 0
    try d_body.appendSlice(allocator, &[_]u8{ 0x00, 0x10, 0x40, 0x00 }); // 0x401000
    try d_body.appendSlice(allocator, &[_]u8{ 0x50, 0x03, 0x00, 0x00 }); // 0x350

    // DIE 2: Subprogram ("calculate_sum", lowpc=0x401020)
    try d_body.append(allocator, 2);
    try d_body.appendSlice(allocator, &[_]u8{ 15, 0, 0, 0 }); // offset 15 ("calculate_sum")
    try d_body.appendSlice(allocator, &[_]u8{ 0x20, 0x10, 0x40, 0x00 }); // 0x401020

    // End of children
    try d_body.append(allocator, 0);

    // Full .debug_info
    var d_info = std.ArrayList(u8).empty;
    defer d_info.deinit(allocator);
    const cu_len: u32 = 2 + 4 + 1 + @as(u32, @intCast(d_body.items.len));
    var cu_hdr: [11]u8 = undefined;
    std.mem.writeInt(u32, cu_hdr[0..4], cu_len, .little);
    std.mem.writeInt(u16, cu_hdr[4..6], 4, .little);
    std.mem.writeInt(u32, cu_hdr[6..10], 0, .little);
    cu_hdr[10] = 4; // 32-bit address

    try d_info.appendSlice(allocator, &cu_hdr);
    try d_info.appendSlice(allocator, d_body.items);

    var dw_data = try dwarf.Data.init(allocator, .{
        .abbrev = d_abbrev.items,
        .info = d_info.items,
        .str = d_str.items,
    });
    defer dw_data.deinit();

    var dw_reader = dw_data.reader();
    defer dw_reader.deinit();

    std.debug.print("  Compilation Units: {d}\n", .{dw_data.units.len});
    while (try dw_reader.next(allocator)) |entry_val| {
        var entry = entry_val;
        defer entry.deinit();
        if (entry.tag == 0) {
            std.debug.print("    <End of Children>\n", .{});
            continue;
        }

        const tag_name = switch (entry.tag) {
            dwarf.TagCompileUnit => "DW_TAG_compile_unit",
            dwarf.TagSubprogram => "DW_TAG_subprogram",
            else => "DW_TAG_unknown",
        };

        const name = entry.attrString(dwarf.AttrName) orelse "(none)";
        const lowpc = entry.attrAddr(dwarf.AttrLowpc) orelse 0;
        std.debug.print("    - {s} name='{s}' low_pc=0x{x}", .{ tag_name, name, lowpc });
        if (entry.attrInt(dwarf.AttrHighpc)) |high| {
            std.debug.print(" high_pc=0x{x}", .{high});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n=== Demonstration Completed Successfully ===\n", .{});
}
