//! Example demonstrating the complete Cross-Platform Binary Inspection Suite in stdgo:
//! 1. debug.elf   (Linux / Unix ELF32 & ELF64)
//! 2. debug.macho (Apple macOS / iOS Mach-O 32/64 & Universal Fat Binaries)
//! 3. debug.pe    (Microsoft Windows PE32 / PE32+ & COFF Object files)

const std = @import("std");
const stdgo = @import("stdgo");
const elf = stdgo.debug.elf;
const macho = stdgo.debug.macho;
const pe = stdgo.debug.pe;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo Cross-Platform Binary Formats Suite (ELF, Mach-O, PE) ===\n\n", .{});

    // ---------------------------------------------------------
    // 1. debug.elf: Linux / Unix ELF64 Binary Parser
    // ---------------------------------------------------------
    std.debug.print("[1] debug.elf (Linux / Unix ELF64) Demo:\n", .{});

    var elf_buf: [512]u8 = @splat(0);
    @memcpy(elf_buf[0..4], elf.ELFMAG);
    elf_buf[4] = 2; // ELFCLASS64
    elf_buf[5] = 1; // ELFDATA2LSB
    elf_buf[6] = 1; // EV_CURRENT
    elf_buf[7] = 3; // ELFOSABI_LINUX

    std.mem.writeInt(u16, elf_buf[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, elf_buf[18..20], 62, .little); // EM_X86_64
    std.mem.writeInt(u64, elf_buf[24..32], 0x401000, .little); // Entry point

    std.mem.writeInt(u64, elf_buf[40..48], 64, .little); // Section header offset
    std.mem.writeInt(u16, elf_buf[58..60], 64, .little);
    std.mem.writeInt(u16, elf_buf[60..62], 2, .little);
    std.mem.writeInt(u16, elf_buf[62..64], 1, .little); // shstrndx = 1

    const sh1 = elf_buf[128..192];
    std.mem.writeInt(u32, sh1[0..4], 1, .little);
    std.mem.writeInt(u32, sh1[4..8], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u64, sh1[24..32], 192, .little);
    std.mem.writeInt(u64, sh1[32..40], 16, .little);

    const shstr_data = "\x00.shstrtab\x00";
    @memcpy(elf_buf[192 .. 192 + shstr_data.len], shstr_data);

    var elf_file = try elf.File.parse(allocator, &elf_buf);
    defer elf_file.deinit();

    std.debug.print("    Class:        {s}\n", .{@tagName(elf_file.header.class)});
    std.debug.print("    Machine:      {s}\n", .{@tagName(elf_file.header.machine)});
    std.debug.print("    Type:         {s}\n", .{@tagName(elf_file.header.type)});
    std.debug.print("    Entry Point:  0x{x}\n", .{elf_file.header.entry});
    std.debug.print("    Section:      '{s}' (type={s})\n", .{
        elf_file.sections[1].header.name,
        @tagName(elf_file.sections[1].header.type),
    });

    // ---------------------------------------------------------
    // 2. debug.macho: macOS / iOS 64-bit Mach-O & Universal Fat
    // ---------------------------------------------------------
    std.debug.print("\n[2] debug.macho (Apple macOS Mach-O & Fat) Demo:\n", .{});

    var macho_buf: [512]u8 = @splat(0);
    std.mem.writeInt(u32, macho_buf[0..4], macho.Magic64, .little);
    std.mem.writeInt(u32, macho_buf[4..8], @intFromEnum(macho.Cpu.arm64), .little);
    std.mem.writeInt(u32, macho_buf[12..16], @intFromEnum(macho.Type.exec), .little);
    std.mem.writeInt(u32, macho_buf[16..20], 2, .little); // 2 commands: segment_64 + load_dylib
    std.mem.writeInt(u32, macho_buf[20..24], 152 + 48, .little);

    // Segment __TEXT with section __text
    const seg = macho_buf[32 .. 32 + 152];
    std.mem.writeInt(u32, seg[0..4], @intFromEnum(macho.LoadCmd.segment_64), .little);
    std.mem.writeInt(u32, seg[4..8], 152, .little);
    @memcpy(seg[8..14], "__TEXT");
    std.mem.writeInt(u64, seg[24..32], 0x100000000, .little);
    std.mem.writeInt(u64, seg[32..40], 0x8000, .little);
    std.mem.writeInt(u32, seg[64..68], 1, .little); // nsects = 1

    const sec = seg[72..152];
    @memcpy(sec[0..6], "__text");
    @memcpy(sec[16..22], "__TEXT");
    std.mem.writeInt(u64, sec[32..40], 0x100001000, .little);
    std.mem.writeInt(u64, sec[40..48], 128, .little);

    // LC_LOAD_DYLIB
    const dylib_cmd = macho_buf[184 .. 184 + 48];
    std.mem.writeInt(u32, dylib_cmd[0..4], @intFromEnum(macho.LoadCmd.load_dylib), .little);
    std.mem.writeInt(u32, dylib_cmd[4..8], 48, .little);
    std.mem.writeInt(u32, dylib_cmd[8..12], 16, .little);
    const dylib_name = "/usr/lib/libSystem.B.dylib\x00";
    @memcpy(dylib_cmd[16 .. 16 + dylib_name.len], dylib_name);

    var macho_file = try macho.File.parse(allocator, &macho_buf);
    defer macho_file.deinit();

    std.debug.print("    CPU Target:   {s}\n", .{@tagName(macho_file.header.cpu)});
    std.debug.print("    File Type:    {s}\n", .{@tagName(macho_file.header.type)});
    std.debug.print("    Segment:      '{s}' (vmaddr=0x{x}, vmsize=0x{x})\n", .{
        macho_file.segments[0].header.name,
        macho_file.segments[0].header.vmaddr,
        macho_file.segments[0].header.vmsize,
    });
    std.debug.print("    Section:      '{s}' (addr=0x{x}, size={d})\n", .{
        macho_file.sections[0].header.name,
        macho_file.sections[0].header.addr,
        macho_file.sections[0].header.size,
    });
    std.debug.print("    Linked Dylib: '{s}'\n", .{macho_file.importedLibraries()[0]});

    // ---------------------------------------------------------
    // 3. debug.pe: Windows PE32+ (64-bit) Executable Parser
    // ---------------------------------------------------------
    std.debug.print("\n[3] debug.pe (Windows PE/COFF 64-bit) Demo:\n", .{});

    var pe_buf: [512]u8 = @splat(0);
    std.mem.writeInt(u16, pe_buf[0..2], pe.IMAGE_DOS_SIGNATURE, .little); // "MZ"
    std.mem.writeInt(u32, pe_buf[0x3c..0x40], 128, .little); // e_lfanew = 128

    std.mem.writeInt(u32, pe_buf[128..132], pe.IMAGE_NT_SIGNATURE, .little); // "PE\0\0"
    std.mem.writeInt(u16, pe_buf[132..134], @intFromEnum(pe.Machine.amd64), .little);
    std.mem.writeInt(u16, pe_buf[134..136], 1, .little); // 1 section
    std.mem.writeInt(u16, pe_buf[148..150], 112, .little); // Optional header size

    // OptionalHeader PE32+
    std.mem.writeInt(u16, pe_buf[152..154], @intFromEnum(pe.OptionalHeaderMagic.pe32_plus), .little);
    std.mem.writeInt(u32, pe_buf[168..172], 0x1400, .little); // AddressOfEntryPoint
    std.mem.writeInt(u64, pe_buf[176..184], 0x140000000, .little); // ImageBase
    std.mem.writeInt(u16, pe_buf[220..222], @intFromEnum(pe.Subsystem.windows_cui), .little);

    // Section .text
    const pe_sec = pe_buf[264..304];
    @memcpy(pe_sec[0..5], ".text");
    std.mem.writeInt(u32, pe_sec[8..12], 0x200, .little);
    std.mem.writeInt(u32, pe_sec[12..16], 0x1000, .little);
    std.mem.writeInt(u32, pe_sec[16..20], 64, .little);
    std.mem.writeInt(u32, pe_sec[20..24], 320, .little);

    pe_buf[320] = 0xcc; // int3
    pe_buf[321] = 0xc3; // ret

    var pe_file = try pe.File.parse(allocator, &pe_buf);
    defer pe_file.deinit();

    std.debug.print("    Machine:      {s}\n", .{@tagName(pe_file.file_header.machine)});
    std.debug.print("    Subsystem:    {s}\n", .{@tagName(pe_file.optional_header.?.subsystem)});
    std.debug.print("    Image Base:   0x{x}\n", .{pe_file.optional_header.?.image_base});
    std.debug.print("    Entry Point:  0x{x}\n", .{pe_file.optional_header.?.address_of_entry_point});
    std.debug.print("    Section:      '{s}' (vaddr=0x{x}, raw_size={d})\n", .{
        pe_file.sections[0].header.name,
        pe_file.sections[0].header.virtual_address,
        pe_file.sections[0].header.size,
    });

    std.debug.print("\n=== All Binary Formats Suite Demos Completed Successfully! ===\n", .{});
}
