//! Example demonstrating the 5 new standard library modules in stdgo:
//! 1. unicode (Category classification, casing, simpleFold)
//! 2. expvar (Thread-safe runtime metrics & JSON export)
//! 3. compress.lzw (RFC LZW compression/decompression for GIF & PDF)
//! 4. index.suffixarray (Logarithmic substring search via suffix arrays)
//! 5. testing.quick (Property-based arbitrary fuzzing & invariants)

const std = @import("std");
const stdgo = @import("stdgo");
const unicode = stdgo.unicode;
const expvar = stdgo.expvar;
const compress = stdgo.compress;
const index = stdgo.index;
const quick = stdgo.testing_pkg.quick;
const bytes = stdgo.bytes;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: Non-Crypto Suite (unicode, expvar, lzw, suffixarray, quick) ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. unicode Classification & Case Folding
    // -------------------------------------------------------------
    std.debug.print("--- 1. unicode Classification & Case Folding ---\n", .{});
    const test_runes = [_]u21{ 'A', 'z', '9', ' ', 0x4E2D, 0x3000, 0x3002, 0x212A };

    for (test_runes) |r| {
        std.debug.print("   Rune U+{X:0>4} -> letter: {}, digit: {}, space: {}, punct: {}\n", .{
            r,
            unicode.isLetter(r),
            unicode.isDigit(r),
            unicode.isSpace(r),
            unicode.isPunct(r),
        });
    }

    std.debug.print("   simpleFold('K') -> U+{X:0>4} -> U+{X:0>4} -> U+{X:0>4}\n", .{
        unicode.simpleFold('K'),
        unicode.simpleFold(unicode.simpleFold('K')),
        unicode.simpleFold(unicode.simpleFold(unicode.simpleFold('K'))),
    });

    // -------------------------------------------------------------
    // 2. expvar Runtime Public Metrics
    // -------------------------------------------------------------
    std.debug.print("\n--- 2. expvar Runtime Public Metrics ---\n", .{});
    var reg = expvar.Registry.init(gpa);
    defer reg.deinit();

    var req_counter = expvar.Int{};
    req_counter.set(1000);
    req_counter.add(42);
    try reg.publish("http_requests_total", req_counter.var_ref());

    var app_version = try expvar.String.init(gpa, "stdgo-v1.0.0");
    defer app_version.deinit();
    try reg.publish("app_version", app_version.var_ref());

    var api_latencies = try expvar.Map.init(gpa);
    defer api_latencies.deinit();
    try api_latencies.add("p50_ms", 12);
    try api_latencies.add("p99_ms", 45);
    try reg.publish("latencies", api_latencies.var_ref());

    const metrics_json = try reg.toJson(gpa);
    defer gpa.free(metrics_json);
    std.debug.print("   Exported Metrics JSON:\n   {s}\n", .{metrics_json});

    // -------------------------------------------------------------
    // 3. compress.lzw (LSB & MSB)
    // -------------------------------------------------------------
    std.debug.print("\n--- 3. compress.lzw Variable-Bit Compression ---\n", .{});
    const sample_data = "TOBEORNOTTOBEORTOBEORNOT#WIKI_COMPRESS";

    var compressed_buf = bytes.Buffer.init(gpa);
    defer compressed_buf.deinit();

    // Compress using LSB (GIF mode)
    var lzw_writer = try compress.lzw.newWriter(compressed_buf.writer(), .LSB, 8);
    _ = try lzw_writer.write(sample_data);
    try lzw_writer.close();

    std.debug.print("   Original Size: {d} bytes, LZW Compressed Size: {d} bytes\n", .{
        sample_data.len,
        compressed_buf.bytes().len,
    });

    // Decompress
    var reader_stream = bytes.Reader.init(compressed_buf.bytes());
    var lzw_reader = try compress.lzw.newReader(reader_stream.reader(), .LSB, 8);
    var decomp_buf: [128]u8 = undefined;
    const dn = try lzw_reader.read(&decomp_buf);
    std.debug.print("   Decompressed Output: '{s}' (matches: {})\n", .{
        decomp_buf[0..dn],
        std.mem.eql(u8, sample_data, decomp_buf[0..dn]),
    });

    // -------------------------------------------------------------
    // 4. index.suffixarray Substring Search
    // -------------------------------------------------------------
    std.debug.print("\n--- 4. index.suffixarray Fast In-Memory Full-Text Search ---\n", .{});
    const corpus = "the quick brown fox jumps over the lazy dog in the park";
    var sa_index = try index.suffixarray.new(gpa, corpus);
    defer sa_index.deinit();

    const the_matches = try sa_index.findAllIndex("the", gpa);
    defer gpa.free(the_matches);

    std.debug.print("   Found {d} occurrences of 'the' at offsets: ", .{the_matches.len});
    for (the_matches, 0..) |offset, i| {
        std.debug.print("{d}{s}", .{ offset, if (i + 1 < the_matches.len) ", " else "\n" });
    }

    // -------------------------------------------------------------
    // 5. testing.quick Property-Based Testing
    // -------------------------------------------------------------
    std.debug.print("\n--- 5. testing.quick Property-Based Invariant Verification ---\n", .{});

    // Verify invariant: (a ^ b) ^ b == a for any 64-bit integers
    const xor_inv = struct {
        fn checkXor(a: u64, b: u64) bool {
            return ((a ^ b) ^ b) == a;
        }
    }.checkXor;

    try quick.check(xor_inv, .{ .max_count = 200 });
    std.debug.print("   Property `((a ^ b) ^ b) == a` verified over 200 random u64 samples: PASSED\n", .{});

    // Verify equivalence: (x * 4) == (x << 2)
    const f_mult = struct {
        fn f(x: u32) u32 {
            return x *% 4;
        }
    }.f;
    const g_shift = struct {
        fn g(x: u32) u32 {
            return x << 2;
        }
    }.g;

    try quick.checkEqual(f_mult, g_shift, .{ .max_count = 200 });
    std.debug.print("   Equivalence `x * 4 == x << 2` verified over 200 random u32 samples: PASSED\n", .{});

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
