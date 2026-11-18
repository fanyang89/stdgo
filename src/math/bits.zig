//! Package math/bits implements bit counting and manipulation functions
//! for the predeclared unsigned integer types.

const std = @import("std");

/// LeadingZeros8 returns the number of leading zero bits in x; the result is 8 for x == 0.
pub fn leadingZeros8(x: u8) usize {
    return @clz(x);
}

/// LeadingZeros16 returns the number of leading zero bits in x; the result is 16 for x == 0.
pub fn leadingZeros16(x: u16) usize {
    return @clz(x);
}

/// LeadingZeros32 returns the number of leading zero bits in x; the result is 32 for x == 0.
pub fn leadingZeros32(x: u32) usize {
    return @clz(x);
}

/// LeadingZeros64 returns the number of leading zero bits in x; the result is 64 for x == 0.
pub fn leadingZeros64(x: u64) usize {
    return @clz(x);
}

/// TrailingZeros8 returns the number of trailing zero bits in x; the result is 8 for x == 0.
pub fn trailingZeros8(x: u8) usize {
    return @ctz(x);
}

/// TrailingZeros16 returns the number of trailing zero bits in x; the result is 16 for x == 0.
pub fn trailingZeros16(x: u16) usize {
    return @ctz(x);
}

/// TrailingZeros32 returns the number of trailing zero bits in x; the result is 32 for x == 0.
pub fn trailingZeros32(x: u32) usize {
    return @ctz(x);
}

/// TrailingZeros64 returns the number of trailing zero bits in x; the result is 64 for x == 0.
pub fn trailingZeros64(x: u64) usize {
    return @ctz(x);
}

/// OnesCount8 returns the number of one bits ("population count") in x.
pub fn onesCount8(x: u8) usize {
    return @popCount(x);
}

/// OnesCount16 returns the number of one bits ("population count") in x.
pub fn onesCount16(x: u16) usize {
    return @popCount(x);
}

/// OnesCount32 returns the number of one bits ("population count") in x.
pub fn onesCount32(x: u32) usize {
    return @popCount(x);
}

/// OnesCount64 returns the number of one bits ("population count") in x.
pub fn onesCount64(x: u64) usize {
    return @popCount(x);
}

/// RotateLeft8 returns the value of x rotated left by (k mod 8) bits.
pub fn rotateLeft8(x: u8, k: i32) u8 {
    const s: u3 = @truncate(@as(u32, @bitCast(k)));
    return std.math.rotl(u8, x, s);
}

/// RotateLeft16 returns the value of x rotated left by (k mod 16) bits.
pub fn rotateLeft16(x: u16, k: i32) u16 {
    const s: u4 = @truncate(@as(u32, @bitCast(k)));
    return std.math.rotl(u16, x, s);
}

/// RotateLeft32 returns the value of x rotated left by (k mod 32) bits.
pub fn rotateLeft32(x: u32, k: i32) u32 {
    const s: u5 = @truncate(@as(u32, @bitCast(k)));
    return std.math.rotl(u32, x, s);
}

/// RotateLeft64 returns the value of x rotated left by (k mod 64) bits.
pub fn rotateLeft64(x: u64, k: i64) u64 {
    const s: u6 = @truncate(@as(u64, @bitCast(k)));
    return std.math.rotl(u64, x, s);
}

/// Reverse8 returns the value of x with its bits in reversed order.
pub fn reverse8(x: u8) u8 {
    return @bitReverse(x);
}

/// Reverse16 returns the value of x with its bits in reversed order.
pub fn reverse16(x: u16) u16 {
    return @bitReverse(x);
}

/// Reverse32 returns the value of x with its bits in reversed order.
pub fn reverse32(x: u32) u32 {
    return @bitReverse(x);
}

/// Reverse64 returns the value of x with its bits in reversed order.
pub fn reverse64(x: u64) u64 {
    return @bitReverse(x);
}

/// ReverseBytes16 returns the value of x with its bytes in reversed order.
pub fn reverseBytes16(x: u16) u16 {
    return @byteSwap(x);
}

/// ReverseBytes32 returns the value of x with its bytes in reversed order.
pub fn reverseBytes32(x: u32) u32 {
    return @byteSwap(x);
}

/// ReverseBytes64 returns the value of x with its bytes in reversed order.
pub fn reverseBytes64(x: u64) u64 {
    return @byteSwap(x);
}

/// Len8 returns the minimum number of bits required to represent x; the result is 0 for x == 0.
pub fn len8(x: u8) usize {
    return 8 - leadingZeros8(x);
}

/// Len16 returns the minimum number of bits required to represent x; the result is 0 for x == 0.
pub fn len16(x: u16) usize {
    return 16 - leadingZeros16(x);
}

/// Len32 returns the minimum number of bits required to represent x; the result is 0 for x == 0.
pub fn len32(x: u32) usize {
    return 32 - leadingZeros32(x);
}

/// Len64 returns the minimum number of bits required to represent x; the result is 0 for x == 0.
pub fn len64(x: u64) usize {
    return 64 - leadingZeros64(x);
}

/// AddResult64 represents the sum and carry out from Add64.
pub const AddResult64 = struct {
    sum: u64,
    carry_out: u64,
};

/// Add64 returns the sum with carry of x, y and carry: sum = x + y + carry.
/// The carry input must be 0 or 1; carry_out is either 0 or 1.
pub fn add64(x: u64, y: u64, carry: u64) AddResult64 {
    const sum1, const c1 = @addWithOverflow(x, y);
    const sum2, const c2 = @addWithOverflow(sum1, carry);
    return .{
        .sum = sum2,
        .carry_out = @as(u64, c1) + @as(u64, c2),
    };
}

/// SubResult64 represents the difference and borrow out from Sub64.
pub const SubResult64 = struct {
    diff: u64,
    borrow_out: u64,
};

/// Sub64 returns the difference of x, y and borrow, diff = x - y - borrow.
/// The borrow input must be 0 or 1; borrow_out is either 0 or 1.
pub fn sub64(x: u64, y: u64, borrow: u64) SubResult64 {
    const diff1, const b1 = @subWithOverflow(x, y);
    const diff2, const b2 = @subWithOverflow(diff1, borrow);
    return .{
        .diff = diff2,
        .borrow_out = @as(u64, b1) + @as(u64, b2),
    };
}

/// MulResult64 represents the 128-bit product (hi, lo) from Mul64.
pub const MulResult64 = struct {
    hi: u64,
    lo: u64,
};

/// Mul64 returns the 128-bit product of x and y: (hi, lo) = x * y.
pub fn mul64(x: u64, y: u64) MulResult64 {
    const prod: u128 = @as(u128, x) * @as(u128, y);
    return .{
        .hi = @intCast(prod >> 64),
        .lo = @intCast(prod & 0xffffffffffffffff),
    };
}

/// DivResult64 represents the quotient and remainder from Div64.
pub const DivResult64 = struct {
    quo: u64,
    rem: u64,
};

/// Div64 returns the quotient and remainder of (hi, lo) divided by y:
/// quo = (hi, lo)/y, rem = (hi, lo)%y.
/// Returns error.DivisionByZero if y == 0, or error.Overflow if hi >= y.
pub fn div64(hi: u64, lo: u64, y: u64) error{ DivisionByZero, Overflow }!DivResult64 {
    if (y == 0) return error.DivisionByZero;
    if (hi >= y) return error.Overflow;
    const num: u128 = (@as(u128, hi) << 64) | @as(u128, lo);
    const quo: u128 = num / y;
    const rem: u128 = num % y;
    return .{
        .quo = @intCast(quo),
        .rem = @intCast(rem),
    };
}

test "math/bits counts and shifts" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 8), leadingZeros8(0));
    try testing.expectEqual(@as(usize, 0), leadingZeros8(0x80));
    try testing.expectEqual(@as(usize, 64), leadingZeros64(0));
    try testing.expectEqual(@as(usize, 0), leadingZeros64(1 << 63));

    try testing.expectEqual(@as(usize, 8), trailingZeros8(0));
    try testing.expectEqual(@as(usize, 3), trailingZeros8(0x08));
    try testing.expectEqual(@as(usize, 64), trailingZeros64(0));
    try testing.expectEqual(@as(usize, 10), trailingZeros64(1 << 10));

    try testing.expectEqual(@as(usize, 0), onesCount8(0));
    try testing.expectEqual(@as(usize, 4), onesCount8(0x0f));
    try testing.expectEqual(@as(usize, 64), onesCount64(0xffffffffffffffff));

    try testing.expectEqual(@as(usize, 0), len64(0));
    try testing.expectEqual(@as(usize, 1), len64(1));
    try testing.expectEqual(@as(usize, 11), len64(1024));

    try testing.expectEqual(@as(u32, 0x00000002), rotateLeft32(0x00000001, 1));
    try testing.expectEqual(@as(u32, 0x80000000), rotateLeft32(0x00000001, -1));

    try testing.expectEqual(@as(u16, 0x3412), reverseBytes16(0x1234));
    try testing.expectEqual(@as(u32, 0x78563412), reverseBytes32(0x12345678));
}

test "math/bits multi-word arithmetic" {
    const testing = std.testing;

    // Add with carry
    const add_res = add64(0xffffffffffffffff, 1, 0);
    try testing.expectEqual(@as(u64, 0), add_res.sum);
    try testing.expectEqual(@as(u64, 1), add_res.carry_out);

    // Sub with borrow
    const sub_res = sub64(0, 1, 0);
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), sub_res.diff);
    try testing.expectEqual(@as(u64, 1), sub_res.borrow_out);

    // Mul
    const mul_res = mul64(1 << 32, 1 << 32);
    try testing.expectEqual(@as(u64, 1), mul_res.hi);
    try testing.expectEqual(@as(u64, 0), mul_res.lo);

    // Div
    const div_res = try div64(0, 100, 7);
    try testing.expectEqual(@as(u64, 14), div_res.quo);
    try testing.expectEqual(@as(u64, 2), div_res.rem);

    // Div 128-bit
    const div128 = try div64(1, 0, 0xffffffffffffffff);
    try testing.expectEqual(@as(u64, 1), div128.quo);
    try testing.expectEqual(@as(u64, 1), div128.rem);
}
