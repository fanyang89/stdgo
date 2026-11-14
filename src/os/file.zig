//! Port of Go's `os` file operations to Zig 0.17.
//!
//! Provides `os.File` implementing `stdgo.io.Reader`, `stdgo.io.Writer`,
//! `stdgo.io.Seeker`, `stdgo.io.Closer`, as well as convenient file functions:
//! `open`, `create`, `readFile`, `writeFile`, `mkdir`, `mkdirAll`, `readDir`,
//! `remove`, `removeAll`, `stat`.

const std = @import("std");
const io_mod = @import("../io.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const StdFile = std.Io.File;

pub const FileInfo = struct {
    name: []const u8,
    size: u64,
    mode: u32,
    mod_time: i64,
    is_dir: bool,
};

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    kind: StdFile.Kind,
};

/// File represents an open file descriptor.
pub const File = struct {
    handle: StdFile,
    io: Io,
    name: []const u8,
    r_buffer: [4096]u8 = undefined,
    w_buffer: [4096]u8 = undefined,
    reader_inst: StdFile.Reader = undefined,
    writer_inst: StdFile.Writer = undefined,
    reader_init: bool = false,
    writer_init: bool = false,
    closed: bool = false,

    pub fn init(handle: StdFile, io: Io, name: []const u8) File {
        return .{
            .handle = handle,
            .io = io,
            .name = name,
            .reader_init = false,
            .writer_init = false,
            .closed = false,
        };
    }

    /// Reader returns the stream interface implementing *stdgo.io.Reader.
    pub fn reader(self: *File) *io_mod.Reader {
        if (!self.reader_init) {
            self.reader_inst = self.handle.reader(self.io, &self.r_buffer);
            self.reader_init = true;
        }
        return &self.reader_inst.interface;
    }

    /// Writer returns the stream interface implementing *stdgo.io.Writer.
    pub fn writer(self: *File) *io_mod.Writer {
        if (!self.writer_init) {
            self.writer_inst = self.handle.writer(self.io, &self.w_buffer);
            self.writer_init = true;
        }
        return &self.writer_inst.interface;
    }

    /// Read reads up to buf.len bytes into buf.
    pub fn read(self: *File, buf: []u8) !usize {
        return self.reader().readSliceShort(buf);
    }

    /// Write writes len(b) bytes to the File.
    pub fn write(self: *File, b: []const u8) !usize {
        try self.writer().writeAll(b);
        return b.len;
    }

    /// WriteString is like Write, but writes the contents of string s.
    pub fn writeString(self: *File, s: []const u8) !usize {
        return self.write(s);
    }

    /// Seek sets the offset for the next Read or Write on file.
    pub fn seek(self: *File, offset: i64, whence: io_mod.SeekWhence) !u64 {
        if (self.writer_init) {
            try self.writer_inst.interface.flush();
        }
        const r_stream = self.reader();
        _ = r_stream;
        switch (whence) {
            .start => {
                if (offset < 0) return error.InvalidArgument;
                try self.reader_inst.seekTo(@intCast(offset));
                return @intCast(offset);
            },
            .current => {
                try self.reader_inst.seekBy(offset);
                return self.reader_inst.logicalPos();
            },
            .end => {
                const st = try self.handle.stat(self.io);
                const target = @as(i64, @intCast(st.size)) + offset;
                if (target < 0) return error.InvalidArgument;
                try self.reader_inst.seekTo(@intCast(target));
                return @intCast(target);
            },
        }
    }

    /// Stat returns the FileInfo structure describing file.
    pub fn stat(self: *File) !FileInfo {
        const st = try self.handle.stat(self.io);
        return FileInfo{
            .name = self.name,
            .size = st.size,
            .mode = @intFromEnum(st.permissions),
            .mod_time = @truncate(st.mtime.nanoseconds),
            .is_dir = st.kind == .directory,
        };
    }

    /// Sync commits the current contents of the file to stable storage.
    pub fn sync(self: *File) !void {
        if (self.writer_init) {
            try self.writer_inst.interface.flush();
        }
        try self.handle.sync(self.io);
    }

    /// Close closes the File, rendering it unusable for I/O.
    pub fn close(self: *File) void {
        if (self.closed) return;
        self.closed = true;
        if (self.writer_init) {
            self.writer_inst.interface.flush() catch {};
        }
        self.handle.close(self.io);
    }
};

/// Open opens the named file for reading.
pub fn open(io: Io, path: []const u8) !File {
    const handle = try Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    return File.init(handle, io, path);
}

/// Create creates or truncates the named file.
pub fn create(io: Io, path: []const u8) !File {
    const handle = try Dir.createFile(.cwd(), io, path, .{ .read = true, .truncate = true });
    return File.init(handle, io, path);
}

/// ReadFile reads the named file and returns the contents.
pub fn readFile(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    var f = try open(io, path);
    defer f.close();

    const st = try f.stat();
    const buf = try allocator.alloc(u8, @intCast(st.size));
    errdefer allocator.free(buf);

    _ = try io_mod.readFull(f.reader(), buf);
    return buf;
}

/// WriteFile writes data to the named file, creating it if necessary.
pub fn writeFile(io: Io, path: []const u8, data: []const u8, perm: u32) !void {
    _ = perm;
    var f = try create(io, path);
    defer f.close();

    _ = try f.write(data);
    try f.sync();
}

/// Mkdir creates a new directory with the specified permissions.
pub fn mkdir(io: Io, path: []const u8, perm: u32) !void {
    _ = perm;
    try Dir.createDir(.cwd(), io, path, .default_dir);
}

/// MkdirAll creates a directory named path, along with any necessary parents.
pub fn mkdirAll(io: Io, path: []const u8, perm: u32) !void {
    _ = perm;
    try Dir.createDirPath(.cwd(), io, path);
}

/// Remove removes the named file or directory.
pub fn remove(io: Io, path: []const u8) !void {
    Dir.deleteFile(.cwd(), io, path) catch |err| switch (err) {
        error.IsDir => try Dir.deleteDir(.cwd(), io, path),
        else => |e| return e,
    };
}

/// RemoveAll removes path and any children it contains.
pub fn removeAll(io: Io, path: []const u8) !void {
    try Dir.deleteTree(.cwd(), io, path);
}

/// Stat returns a FileInfo describing the named file.
pub fn stat(io: Io, path: []const u8) !FileInfo {
    const st = try Dir.statFile(.cwd(), io, path, .{});
    return FileInfo{
        .name = std.fs.path.basename(path),
        .size = st.size,
        .mode = @intFromEnum(st.permissions),
        .mod_time = @truncate(st.mtime.nanoseconds),
        .is_dir = st.kind == .directory,
    };
}

/// ReadDir reads the named directory, returning all its directory entries sorted by filename.
pub fn readDir(allocator: Allocator, io: Io, path: []const u8) ![]DirEntry {
    const dir = try Dir.openDir(.cwd(), io, path, .{ .iterate = true });
    defer dir.close(io);

    var list = std.ArrayList(DirEntry).empty;
    errdefer {
        for (list.items) |e| allocator.free(e.name);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const owned_name = try allocator.dupe(u8, entry.name);
        try list.append(allocator, .{
            .name = owned_name,
            .is_dir = entry.kind == .directory,
            .kind = entry.kind,
        });
    }

    return try list.toOwnedSlice(allocator);
}

// -------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------

test "os.file: create, write, seek, read, remove" {
    const testing = std.testing;
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const test_dir = "test_os_scratch_dir";
    mkdirAll(io, test_dir, 0o755) catch {};
    defer removeAll(io, test_dir) catch {};

    const test_path = test_dir ++ "/test_file.txt";

    // 1. Create and write
    var f = try create(io, test_path);
    defer f.close();

    _ = try f.write("Hello from stdgo os.File!\n");
    _ = try f.writeString("Second line of content.\n");
    try f.sync();

    // 2. Seek and read
    _ = try f.seek(0, .start);
    var read_buf: [32]u8 = undefined;
    const n = try f.read(&read_buf);
    try testing.expect(std.mem.startsWith(u8, read_buf[0..n], "Hello from stdgo os.File!\n"));

    // 3. Stat
    const info = try f.stat();
    try testing.expect(info.size > 25);
    try testing.expect(!info.is_dir);

    // 4. readFile convenience
    const content = try readFile(testing.allocator, io, test_path);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Second line of content.") != null);

    // 5. readDir
    const entries = try readDir(testing.allocator, io, test_dir);
    defer {
        for (entries) |e| testing.allocator.free(e.name);
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("test_file.txt", entries[0].name);
}
