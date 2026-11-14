//! Package bufio implements buffered I/O. It wraps an io.Reader or io.Writer object,
//! creating another object (Reader, Writer, or Scanner) that also implements the interface
//! but provides buffering and some help for textual I/O.

const std = @import("std");

pub const scanner = @import("bufio/scanner.zig");
pub const Scanner = scanner.Scanner;
pub const SplitFunc = scanner.SplitFunc;
pub const SplitResult = scanner.SplitResult;
pub const scanLines = scanner.scanLines;
pub const scanWords = scanner.scanWords;
pub const scanBytes = scanner.scanBytes;
pub const scanRunes = scanner.scanRunes;

test {
    std.testing.refAllDecls(@This());
    _ = scanner;
}
