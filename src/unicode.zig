//! Package unicode provides data and functions to define some properties of Unicode code points.
const std = @import("std");

pub const utf8 = @import("unicode/utf8.zig");
pub const utf16 = @import("unicode/utf16.zig");
pub const letter = @import("unicode/letter.zig");

// Constants
pub const MaxRune = letter.MaxRune;
pub const ReplacementChar = letter.ReplacementChar;
pub const MaxASCII = letter.MaxASCII;
pub const MaxLatin1 = letter.MaxLatin1;

// Range types
pub const Range16 = letter.Range16;
pub const Range32 = letter.Range32;
pub const RangeTable = letter.RangeTable;

// Classification & case folding
pub const is = letter.is;
pub const isDigit = letter.isDigit;
pub const isNumber = letter.isNumber;
pub const isLetter = letter.isLetter;
pub const isSpace = letter.isSpace;
pub const isPunct = letter.isPunct;
pub const isControl = letter.isControl;
pub const isUpper = letter.isUpper;
pub const isLower = letter.isLower;
pub const toUpper = letter.toUpper;
pub const toLower = letter.toLower;
pub const simpleFold = letter.simpleFold;

test {
    @import("std").testing.refAllDecls(@This());
    _ = utf8;
    _ = utf16;
    _ = letter;
}

test "unicode classification: isLetter, isDigit, isSpace, isPunct" {
    const testing = std.testing;

    // isLetter
    try testing.expect(isLetter('a'));
    try testing.expect(isLetter('Z'));
    try testing.expect(isLetter(0x4E2D)); // '中' CJK ideograph
    try testing.expect(isLetter(0x03B1)); // 'α' Greek
    try testing.expect(!isLetter('1'));
    try testing.expect(!isLetter(' '));

    // isDigit
    try testing.expect(isDigit('0'));
    try testing.expect(isDigit('9'));
    try testing.expect(isDigit(0xFF15)); // '５' Fullwidth digit 5
    try testing.expect(!isDigit('a'));
    try testing.expect(!isDigit(' '));

    // isSpace
    try testing.expect(isSpace(' '));
    try testing.expect(isSpace('\t'));
    try testing.expect(isSpace('\n'));
    try testing.expect(isSpace(0x3000)); // Ideographic fullwidth space '　'
    try testing.expect(isSpace(0x00A0)); // Non-breaking space
    try testing.expect(!isSpace('A'));
    try testing.expect(!isSpace('0'));

    // isPunct
    try testing.expect(isPunct('!'));
    try testing.expect(isPunct('?'));
    try testing.expect(isPunct(0x3002)); // '。' CJK Ideographic full stop
    try testing.expect(!isPunct('A'));
    try testing.expect(!isPunct(' '));
}

test "unicode case conversion and simpleFold cycles" {
    const testing = std.testing;

    try testing.expectEqual(@as(u21, 'A'), toUpper('a'));
    try testing.expectEqual(@as(u21, 'a'), toLower('A'));
    try testing.expectEqual(@as(u21, 0x0100), toUpper(0x0101)); // Latin Extended-A Ā / ā

    // SimpleFold cycles
    // 'K' -> 'k' -> 'K' (Kelvin sign 0x212A) -> 'K'
    try testing.expectEqual(@as(u21, 'k'), simpleFold('K'));
    try testing.expectEqual(@as(u21, 0x212A), simpleFold('k'));
    try testing.expectEqual(@as(u21, 'K'), simpleFold(0x212A));

    // 'S' -> 's' -> 'ſ' (0x017F) -> 'S'
    try testing.expectEqual(@as(u21, 's'), simpleFold('S'));
    try testing.expectEqual(@as(u21, 0x017F), simpleFold('s'));
    try testing.expectEqual(@as(u21, 'S'), simpleFold(0x017F));
}
