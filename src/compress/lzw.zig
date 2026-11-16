//! Package lzw implements the Lempel-Ziv-Welch compressed data format,
//! conforming to Go's compress/lzw package and supporting both LSB (GIF) and MSB (TIFF/PDF) orders.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Order = enum {
    LSB, // Least Significant Bit first, as used in GIF
    MSB, // Most Significant Bit first, as used in TIFF and PDF
};

pub const LzwError = error{
    InvalidLiteralWidth,
    CorruptLzwData,
    EndOfStream,
};

const max_code_len = 12;
const max_table_size = 1 << max_code_len; // 4096

/// Reader is an io.Reader that can be used to read LZW-compressed data.
pub const Reader = struct {
    r: *std.Io.Reader,
    order: Order,
    lit_width: u4,
    clear_code: u16,
    eof_code: u16,
    hi: u16,
    width: u4,
    last_code: u16 = 0xFFFF,
    bit_buffer: u32 = 0,
    bits_in_buf: u5 = 0,
    eof_reached: bool = false,

    prefix: [max_table_size]u16 = undefined,
    suffix: [max_table_size]u8 = undefined,

    // Decode stack for current code expansion
    stack: [max_table_size]u8 = undefined,
    stack_pos: usize = 0,

    pub fn init(r: *std.Io.Reader, order: Order, lit_width: u4) LzwError!Reader {
        if (lit_width < 2 or lit_width > 8) {
            return error.InvalidLiteralWidth;
        }

        const clear = @as(u16, 1) << lit_width;
        const eof = clear + 1;

        var self = Reader{
            .r = r,
            .order = order,
            .lit_width = lit_width,
            .clear_code = clear,
            .eof_code = eof,
            .hi = eof + 1,
            .width = lit_width + 1,
        };

        // Initialize literal table
        for (0..clear) |i| {
            self.prefix[i] = 0xFFFF;
            self.suffix[i] = @intCast(i);
        }

        return self;
    }

    fn readBits(self: *Reader, n_bits: u4) !u16 {
        while (self.bits_in_buf < n_bits) {
            const b = self.r.takeByte() catch |err| {
                if (err == error.EndOfStream) {
                    if (self.bits_in_buf == 0) return error.EndOfStream;
                    break;
                }
                return err;
            };

            if (self.order == .LSB) {
                self.bit_buffer |= (@as(u32, b) << self.bits_in_buf);
            } else {
                self.bit_buffer = (self.bit_buffer << 8) | @as(u32, b);
            }
            self.bits_in_buf += 8;
        }

        if (self.bits_in_buf < n_bits) return error.CorruptLzwData;

        var code: u16 = 0;
        if (self.order == .LSB) {
            const mask: u32 = (@as(u32, 1) << n_bits) - 1;
            code = @intCast(self.bit_buffer & mask);
            self.bit_buffer >>= n_bits;
        } else {
            const shift = self.bits_in_buf - n_bits;
            const mask: u32 = (@as(u32, 1) << n_bits) - 1;
            code = @intCast((self.bit_buffer >> shift) & mask);
        }
        self.bits_in_buf -= n_bits;
        return code;
    }

    pub fn read(self: *Reader, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        var out_idx: usize = 0;

        while (out_idx < buf.len) {
            // Drain output stack if any bytes remaining
            if (self.stack_pos > 0) {
                const avail = self.stack_pos;
                const chunk = @min(avail, buf.len - out_idx);
                for (0..chunk) |i| {
                    buf[out_idx + i] = self.stack[self.stack_pos - 1 - i];
                }
                self.stack_pos -= chunk;
                out_idx += chunk;
                if (out_idx == buf.len) return out_idx;
                continue;
            }

            if (self.eof_reached) {
                return out_idx;
            }

            const code = self.readBits(self.width) catch |err| {
                if (err == error.EndOfStream) return out_idx;
                return err;
            };

            if (code == self.clear_code) {
                self.width = self.lit_width + 1;
                self.hi = self.eof_code + 1;
                self.last_code = 0xFFFF;
                continue;
            }

            if (code == self.eof_code) {
                self.eof_reached = true;
                return out_idx;
            }

            if (code > self.hi) {
                return error.CorruptLzwData;
            }

            // Expand code into stack
            var c = code;
            if (code == self.hi) {
                // Special case: code equals next available code
                if (self.last_code == 0xFFFF) return error.CorruptLzwData;
                c = self.last_code;
                var tmp_c = c;
                var loop_count: usize = 0;
                while (self.prefix[tmp_c] != 0xFFFF) {
                    tmp_c = self.prefix[tmp_c];
                    loop_count += 1;
                    if (loop_count > max_table_size) return error.CorruptLzwData;
                }
                if (self.stack_pos >= max_table_size) return error.CorruptLzwData;
                self.stack[self.stack_pos] = self.suffix[tmp_c];
                self.stack_pos += 1;
            }

            var loop_count: usize = 0;
            while (c != 0xFFFF) {
                if (self.stack_pos >= max_table_size) return error.CorruptLzwData;
                self.stack[self.stack_pos] = self.suffix[c];
                self.stack_pos += 1;
                c = self.prefix[c];
                loop_count += 1;
                if (loop_count > max_table_size) return error.CorruptLzwData;
            }

            // Add new dictionary entry
            if (self.last_code != 0xFFFF and self.hi < max_table_size) {
                const first_byte = self.stack[self.stack_pos - 1];
                self.prefix[self.hi] = self.last_code;
                self.suffix[self.hi] = first_byte;
                self.hi += 1;

                if (self.hi == (@as(u16, 1) << self.width) and self.width < max_code_len) {
                    self.width += 1;
                }
            }

            self.last_code = code;
        }

        return out_idx;
    }
};

/// Writer is an LZW compressor writing variable-bit codes to an underlying std.Io.Writer.
pub const Writer = struct {
    w: *std.Io.Writer,
    order: Order,
    lit_width: u4,
    clear_code: u16,
    eof_code: u16,
    hi: u16,
    width: u4,
    bit_buffer: u32 = 0,
    bits_in_buf: u5 = 0,
    cur_prefix: u16 = 0xFFFF,
    closed: bool = false,

    // Hash table for (prefix, byte) -> code lookup
    hash_keys: [8192]u32 = @splat(0xFFFFFFFF),
    hash_vals: [8192]u16 = @splat(0),

    pub fn init(w: *std.Io.Writer, order: Order, lit_width: u4) anyerror!Writer {
        if (lit_width < 2 or lit_width > 8) {
            return error.InvalidLiteralWidth;
        }

        const clear = @as(u16, 1) << lit_width;
        const eof = clear + 1;

        var self = Writer{
            .w = w,
            .order = order,
            .lit_width = lit_width,
            .clear_code = clear,
            .eof_code = eof,
            .hi = eof + 1,
            .width = lit_width + 1,
        };

        // Write initial clear_code
        try self.writeBits(self.clear_code, self.width);

        return self;
    }

    fn writeBits(self: *Writer, code: u16, n_bits: u4) !void {
        if (self.order == .LSB) {
            self.bit_buffer |= (@as(u32, code) << self.bits_in_buf);
            self.bits_in_buf += n_bits;
            while (self.bits_in_buf >= 8) {
                const b: u8 = @intCast(self.bit_buffer & 0xFF);
                try self.w.writeByte(b);
                self.bit_buffer >>= 8;
                self.bits_in_buf -= 8;
            }
        } else {
            self.bit_buffer = (self.bit_buffer << n_bits) | @as(u32, code);
            self.bits_in_buf += n_bits;
            while (self.bits_in_buf >= 8) {
                const shift = self.bits_in_buf - 8;
                const b: u8 = @intCast((self.bit_buffer >> shift) & 0xFF);
                try self.w.writeByte(b);
                self.bits_in_buf -= 8;
            }
        }
    }

    fn hashKey(prefix: u16, byte: u8) u32 {
        return (@as(u32, prefix) << 8) | byte;
    }

    fn hashLookup(self: *const Writer, key: u32) ?u16 {
        var h: usize = @intCast((key *% 0x9E3779B1) % self.hash_keys.len);
        while (self.hash_keys[h] != 0xFFFFFFFF) {
            if (self.hash_keys[h] == key) return self.hash_vals[h];
            h = (h + 1) % self.hash_keys.len;
        }
        return null;
    }

    fn hashInsert(self: *Writer, key: u32, val: u16) void {
        var h: usize = @intCast((key *% 0x9E3779B1) % self.hash_keys.len);
        while (self.hash_keys[h] != 0xFFFFFFFF) {
            if (self.hash_keys[h] == key) {
                self.hash_vals[h] = val;
                return;
            }
            h = (h + 1) % self.hash_keys.len;
        }
        self.hash_keys[h] = key;
        self.hash_vals[h] = val;
    }

    fn resetTable(self: *Writer) !void {
        try self.writeBits(self.clear_code, self.width);
        self.width = self.lit_width + 1;
        self.hi = self.eof_code + 1;
        @memset(&self.hash_keys, 0xFFFFFFFF);
    }

    pub fn write(self: *Writer, data: []const u8) !usize {
        for (data) |b| {
            if (self.cur_prefix == 0xFFFF) {
                self.cur_prefix = b;
                continue;
            }

            const key = hashKey(self.cur_prefix, b);
            if (self.hashLookup(key)) |code| {
                self.cur_prefix = code;
            } else {
                try self.writeBits(self.cur_prefix, self.width);

                if (self.hi < max_table_size) {
                    self.hashInsert(key, self.hi);
                    self.hi += 1;

                    if (self.hi > (@as(u16, 1) << self.width)) {
                        if (self.width < max_code_len) {
                            self.width += 1;
                        }
                    }
                } else {
                    try self.resetTable();
                }

                self.cur_prefix = b;
            }
        }
        return data.len;
    }

    pub fn close(self: *Writer) !void {
        if (self.closed) return;
        self.closed = true;

        if (self.cur_prefix != 0xFFFF) {
            try self.writeBits(self.cur_prefix, self.width);
        }
        try self.writeBits(self.eof_code, self.width);

        // Flush leftover bits
        if (self.bits_in_buf > 0) {
            if (self.order == .LSB) {
                const b: u8 = @intCast(self.bit_buffer & 0xFF);
                try self.w.writeByte(b);
            } else {
                const shift = 8 - self.bits_in_buf;
                const b: u8 = @intCast((self.bit_buffer << shift) & 0xFF);
                try self.w.writeByte(b);
            }
            self.bits_in_buf = 0;
            self.bit_buffer = 0;
        }

        try self.w.flush();
    }
};

/// NewReader returns a new Reader.
pub fn newReader(r: *std.Io.Reader, order: Order, lit_width: u4) LzwError!Reader {
    return Reader.init(r, order, lit_width);
}

/// NewWriter returns a new Writer.
pub fn newWriter(w: *std.Io.Writer, order: Order, lit_width: u4) anyerror!Writer {
    return Writer.init(w, order, lit_width);
}

test "compress/lzw roundtrip: LSB (GIF) and MSB (PDF) modes" {
    const testing = std.testing;
    const bytes = @import("../bytes.zig");

    const original_text = "TOBEORNOTTOBEORTOBEORNOT";

    // 1. LSB roundtrip
    {
        var out_buf = bytes.Buffer.init(testing.allocator);
        defer out_buf.deinit();

        var writer = try newWriter(out_buf.writer(), .LSB, 8);
        _ = try writer.write(original_text);
        try writer.close();

        var in_stream = bytes.Reader.init(out_buf.bytes());
        var reader = try newReader(in_stream.reader(), .LSB, 8);

        var decomp_buf: [256]u8 = undefined;
        const n = try reader.read(&decomp_buf);

        try testing.expectEqualStrings(original_text, decomp_buf[0..n]);
    }

    // 2. MSB roundtrip
    {
        var out_buf = bytes.Buffer.init(testing.allocator);
        defer out_buf.deinit();

        var writer = try newWriter(out_buf.writer(), .MSB, 8);
        _ = try writer.write(original_text);
        try writer.close();

        var in_stream = bytes.Reader.init(out_buf.bytes());
        var reader = try newReader(in_stream.reader(), .MSB, 8);

        var decomp_buf: [256]u8 = undefined;
        const n = try reader.read(&decomp_buf);

        try testing.expectEqualStrings(original_text, decomp_buf[0..n]);
    }
}
