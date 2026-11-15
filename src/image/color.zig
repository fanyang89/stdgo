const std = @import("std");

pub const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(self: RGBA) struct { r: u32, g: u32, b: u32, a: u32 } {
        const r: u32 = @as(u32, self.r) * 0x101;
        const g: u32 = @as(u32, self.g) * 0x101;
        const b: u32 = @as(u32, self.b) * 0x101;
        const a: u32 = @as(u32, self.a) * 0x101;
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const NRGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(self: NRGBA) struct { r: u32, g: u32, b: u32, a: u32 } {
        if (self.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (self.a == 0xff) {
            return .{
                .r = @as(u32, self.r) * 0x101,
                .g = @as(u32, self.g) * 0x101,
                .b = @as(u32, self.b) * 0x101,
                .a = 0xffff,
            };
        }
        var r = @as(u32, self.r) * 0x101;
        r = (r * @as(u32, self.a) + 127) / 255;
        var g = @as(u32, self.g) * 0x101;
        g = (g * @as(u32, self.a) + 127) / 255;
        var b = @as(u32, self.b) * 0x101;
        b = (b * @as(u32, self.a) + 127) / 255;
        const a = @as(u32, self.a) * 0x101;
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Gray = struct {
    y: u8,

    pub fn rgba(self: Gray) struct { r: u32, g: u32, b: u32, a: u32 } {
        const val: u32 = @as(u32, self.y) * 0x101;
        return .{ .r = val, .g = val, .b = val, .a = 0xffff };
    }
};

pub const Alpha = struct {
    a: u8,

    pub fn rgba(self: Alpha) struct { r: u32, g: u32, b: u32, a: u32 } {
        const val: u32 = @as(u32, self.a) * 0x101;
        return .{ .r = val, .g = val, .b = val, .a = val };
    }
};

pub const Black = Gray{ .y = 0 };
pub const White = Gray{ .y = 0xff };
pub const Transparent = Alpha{ .a = 0 };
pub const Opaque = Alpha{ .a = 0xff };

test "color conversions" {
    const testing = std.testing;

    const c1 = RGBA{ .r = 0xff, .g = 0x80, .b = 0x00, .a = 0xff };
    const r1 = c1.rgba();
    try testing.expectEqual(@as(u32, 0xffff), r1.r);
    try testing.expectEqual(@as(u32, 0x8080), r1.g);
    try testing.expectEqual(@as(u32, 0), r1.b);
    try testing.expectEqual(@as(u32, 0xffff), r1.a);

    const gray = Gray{ .y = 128 };
    const rg = gray.rgba();
    try testing.expectEqual(@as(u32, 128 * 0x101), rg.r);
    try testing.expectEqual(@as(u32, 128 * 0x101), rg.g);
    try testing.expectEqual(@as(u32, 128 * 0x101), rg.b);
    try testing.expectEqual(@as(u32, 0xffff), rg.a);
}
