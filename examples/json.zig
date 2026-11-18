//! Example demonstrating stdgo encoding.json package:
//! 1. marshal & unmarshal
//! 2. marshalIndent (pretty-printed JSON)
//! 3. Streaming Decoder with Token parsing
//! 4. Streaming Encoder

const std = @import("std");
const stdgo = @import("stdgo");
const json = stdgo.encoding.json;
const bytes = stdgo.bytes;

const ServerConfig = struct {
    name: []const u8,
    port: u16,
    max_connections: u32,
    enable_tls: bool,
    tags: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    std.debug.print("=== stdgo: encoding.json Example ===\n\n", .{});

    // -------------------------------------------------------------
    // 1. marshal & unmarshal
    // -------------------------------------------------------------
    std.debug.print("1. json.marshal & json.unmarshal:\n", .{});

    const tags = [_][]const u8{ "edge", "gateway", "v2" };
    const cfg = ServerConfig{
        .name = "edge-proxy-01",
        .port = 8443,
        .max_connections = 10000,
        .enable_tls = true,
        .tags = &tags,
    };

    const minified = try json.marshal(gpa, cfg);
    defer gpa.free(minified);
    std.debug.print("   Minified: {s}\n", .{minified});

    const parsed = try json.unmarshal(gpa, ServerConfig, minified);
    defer parsed.deinit();
    std.debug.print("   Parsed back: name={s}, port={d}, tls={}\n", .{
        parsed.value.name,
        parsed.value.port,
        parsed.value.enable_tls,
    });

    // -------------------------------------------------------------
    // 2. marshalIndent
    // -------------------------------------------------------------
    std.debug.print("\n2. json.marshalIndent (pretty-printed):\n", .{});

    const indented = try json.marshalIndent(gpa, cfg, "", "  ");
    defer gpa.free(indented);
    std.debug.print("{s}\n", .{indented});

    // -------------------------------------------------------------
    // 3. Streaming Decoder with Token traversal
    // -------------------------------------------------------------
    std.debug.print("3. Streaming json.Decoder with Token iterator:\n", .{});

    const json_stream = "{\"version\": 1, \"items\": [10, 20, 30], \"ok\": true}";
    var r = bytes.Reader.init(json_stream);
    var dec = json.Decoder.init(gpa, r.reader());
    defer dec.deinit();

    std.debug.print("   Tokens: ", .{});
    while (try dec.token()) |tok| {
        switch (tok) {
            .delim => |d| std.debug.print("{c} ", .{@backingInt(d)}),
            .bool => |b| std.debug.print("{s} ", .{if (b) "true" else "false"}),
            .number => |n| std.debug.print("num({s}) ", .{n}),
            .string => |s| std.debug.print("str(\"{s}\") ", .{s}),
            .null => std.debug.print("null ", .{}),
        }
    }
    std.debug.print("\n", .{});

    // -------------------------------------------------------------
    // 4. Streaming Encoder
    // -------------------------------------------------------------
    std.debug.print("\n4. Streaming json.Encoder into bytes.Buffer:\n", .{});

    var out_buf = bytes.Buffer.init(gpa);
    defer out_buf.deinit();

    var enc = json.Encoder.init(gpa, out_buf.writer());
    const batch = [_]i32{ 100, 200, 300, 400 };
    try enc.encode(batch);

    std.debug.print("   Encoded output: {s}", .{out_buf.string()});

    std.debug.print("\nencoding.json demo completed successfully!\n", .{});
}
