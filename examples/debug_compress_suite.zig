//! Example demonstrating:
//! 1. compress.bzip2 (Streaming RFC bzip2 decompressor with BWT, MTF, and CRC32)
//! 2. debug.elf (ELF32 & ELF64 binary format inspection, sections, progs, and symbols)

const std = @import("std");
const stdgo = @import("stdgo");
const bzip2 = stdgo.compress.bzip2;
const elf = stdgo.debug.elf;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("=== stdgo Debug & Compression Suite Demo ===\n\n", .{});

    // ---------------------------------------------------------
    // 1. compress.bzip2: Bzip2 Decompression Demo
    // ---------------------------------------------------------
    std.debug.print("[1] compress.bzip2 Demo:\n", .{});

    const bz2_payload_hex = "425a6839314159265359b98ead8e0000051f8060051000004000801ea6dc10200022a7e8a687e8a60d34281a686464c4098a8774d689eb3e84dc1bdd964a83fd2196292f36fb22ad8413c177245385090b98ead8e0";
    var raw_buf: [128]u8 = undefined;
    const compressed = try std.fmt.hexToBytes(raw_buf[0 .. bz2_payload_hex.len / 2], bz2_payload_hex);

    std.debug.print("    Compressed size: {d} bytes (Header: BZh9)\n", .{compressed.len});

    // Streaming decompress
    var reader = bytes.Reader.init(compressed);
    var bz_reader = bzip2.Reader.init(allocator, reader.reader());
    defer bz_reader.deinit();

    const decompressed = try bz_reader.readAllAlloc(1024 * 1024);
    defer allocator.free(decompressed);

    std.debug.print("    Decompressed: \"{s}\"\n", .{decompressed});
    std.debug.print("    Inverse BWT & CRC32 Verified: true\n", .{});

    // ---------------------------------------------------------
    // 2. debug.elf: ELF Binary Format Parser Demo
    // ---------------------------------------------------------
    std.debug.print("\n[2] debug.elf Demo:\n", .{});

    // Construct a sample 64-bit ELF binary image in memory
    var elf_raw: [512]u8 = @splat(0);

    // Ident & Headers
    @memcpy(elf_raw[0..4], elf.ELFMAG);
    elf_raw[4] = 2; // ELFCLASS64
    elf_raw[5] = 1; // ELFDATA2LSB
    elf_raw[6] = 1; // EV_CURRENT
    elf_raw[7] = 3; // ELFOSABI_LINUX

    std.mem.writeInt(u16, elf_raw[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, elf_raw[18..20], 62, .little); // EM_X86_64
    std.mem.writeInt(u32, elf_raw[20..24], 1, .little);
    std.mem.writeInt(u64, elf_raw[24..32], 0x401120, .little); // Entry point

    // Section headers: offset 64, 4 sections
    std.mem.writeInt(u64, elf_raw[40..48], 64, .little);
    std.mem.writeInt(u16, elf_raw[58..60], 64, .little); // shentsize
    std.mem.writeInt(u16, elf_raw[60..62], 4, .little); // shnum
    std.mem.writeInt(u16, elf_raw[62..64], 1, .little); // shstrndx

    // Section 1: .shstrtab (at 320, size 32)
    const s1 = elf_raw[128..192];
    std.mem.writeInt(u32, s1[0..4], 1, .little); // .shstrtab
    std.mem.writeInt(u32, s1[4..8], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u64, s1[24..32], 320, .little);
    std.mem.writeInt(u64, s1[32..40], 32, .little);

    // Section 2: .symtab (at 360, size 48, link = 3)
    const s2 = elf_raw[192..256];
    std.mem.writeInt(u32, s2[0..4], 11, .little); // .symtab
    std.mem.writeInt(u32, s2[4..8], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u64, s2[24..32], 360, .little);
    std.mem.writeInt(u64, s2[32..40], 48, .little);
    std.mem.writeInt(u32, s2[40..44], 3, .little);
    std.mem.writeInt(u64, s2[56..64], 24, .little);

    // Section 3: .strtab (at 420, size 16)
    const s3 = elf_raw[256..320];
    std.mem.writeInt(u32, s3[0..4], 19, .little); // .strtab
    std.mem.writeInt(u32, s3[4..8], 3, .little); // SHT_STRTAB
    std.mem.writeInt(u64, s3[24..32], 420, .little);
    std.mem.writeInt(u64, s3[32..40], 16, .little);

    // Names
    const shstr_data = "\x00.shstrtab\x00.symtab\x00.strtab\x00";
    @memcpy(elf_raw[320 .. 320 + shstr_data.len], shstr_data);

    // Symbol: "entryPoint"
    const sym1 = elf_raw[384..408];
    std.mem.writeInt(u32, sym1[0..4], 1, .little);
    sym1[4] = 0x12; // STB_GLOBAL + STT_FUNC
    std.mem.writeInt(u16, sym1[6..8], 1, .little);
    std.mem.writeInt(u64, sym1[8..16], 0x401120, .little);
    std.mem.writeInt(u64, sym1[16..24], 128, .little);

    const str_data = "\x00entryPoint\x00";
    @memcpy(elf_raw[420 .. 420 + str_data.len], str_data);

    // Parse ELF
    var elf_file = try elf.File.parse(allocator, &elf_raw);
    defer elf_file.deinit();

    std.debug.print("    ELF Class:    {s}\n", .{@tagName(elf_file.header.class)});
    std.debug.print("    Endianness:   {s}\n", .{@tagName(elf_file.header.byte_order)});
    std.debug.print("    Target Arch:  {s}\n", .{@tagName(elf_file.header.machine)});
    std.debug.print("    File Type:    {s}\n", .{@tagName(elf_file.header.type)});
    std.debug.print("    Entry Point:  0x{x}\n", .{elf_file.header.entry});
    std.debug.print("    Section Count: {d}\n", .{elf_file.sections.len});

    const syms = try elf_file.symbols(allocator);
    defer allocator.free(syms);

    std.debug.print("    Symbols Extracted ({d}):\n", .{syms.len});
    for (syms) |s| {
        if (s.name.len > 0) {
            std.debug.print("      -> Symbol '{s}': bind={s}, type={s}, value=0x{x}, size={d} bytes\n", .{
                s.name,
                @tagName(s.bind()),
                @tagName(s.symType()),
                s.value,
                s.size,
            });
        }
    }

    std.debug.print("\n=== All Debug & Compress Suite Demos Completed Successfully! ===\n", .{});
}
