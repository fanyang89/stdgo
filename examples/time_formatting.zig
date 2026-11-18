const std = @import("std");
const stdgo = @import("stdgo");
const time = stdgo.time;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("=== stdgo.time Formatting & Calendar Demo ===\n\n");

    // 1. Construct Date and Breakdown fields
    const t0 = time.date(2026, .November, 15, 14, 30, 45, 123_456_789, time.Location.fixedZone("CST", 8 * 3600));
    try stdout.print("Time breakdown for 2026-11-15 14:30:45 CST:\n", .{});
    try stdout.print("  Year:       {d}\n", .{t0.year()});
    try stdout.print("  Month:      {s} ({d})\n", .{ t0.month().string(), @backingInt(t0.month()) });
    try stdout.print("  Day:        {d}\n", .{t0.day()});
    try stdout.print("  Weekday:    {s}\n", .{t0.weekday().string()});
    try stdout.print("  Hour:       {d}\n", .{t0.hour()});
    try stdout.print("  Minute:     {d}\n", .{t0.minute()});
    try stdout.print("  Second:     {d}\n", .{t0.second()});
    try stdout.print("  Nanosecond: {d}\n", .{t0.nanosecond()});
    try stdout.print("  YearDay:    Day {d} of year\n\n", .{t0.yearDay()});

    // 2. Format with standard Go layouts
    var buf: [128]u8 = undefined;

    const s_rfc3339 = try t0.format(time.RFC3339, &buf);
    try stdout.print("RFC3339:   {s}\n", .{s_rfc3339});

    const s_dt = try t0.format(time.DateTime, &buf);
    try stdout.print("DateTime:  {s}\n", .{s_dt});

    const s_date = try t0.format(time.DateOnly, &buf);
    try stdout.print("DateOnly:  {s}\n", .{s_date});

    const s_time = try t0.format(time.TimeOnly, &buf);
    try stdout.print("TimeOnly:  {s}\n", .{s_time});

    const s_kitchen = try t0.format(time.Kitchen, &buf);
    try stdout.print("Kitchen:   {s}\n", .{s_kitchen});

    const t_utc = t0.utc();
    const s_http = try t_utc.format(time.RFC1123, &buf);
    try stdout.print("RFC1123:   {s} (HTTP Date Header)\n\n", .{s_http});

    // 3. Parse formatted dates
    try stdout.writeAll("Parsing RFC3339 timestamp back:\n");
    const parsed = try time.parse(time.RFC3339, "2026-11-15T14:30:45+08:00");
    const s_parsed_dt = try parsed.formatAlloc(allocator, time.DateTime);
    defer allocator.free(s_parsed_dt);
    try stdout.print("  Parsed DateTime: {s}\n", .{s_parsed_dt});
    try stdout.print("  Wall seconds:    {d}\n\n", .{parsed.wall_sec});

    try stdout.writeAll("Time demo completed successfully!\n");
    try stdout.flush();
}
