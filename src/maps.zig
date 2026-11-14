const std = @import("std");
const Allocator = std.mem.Allocator;

/// Clone returns a copy of m.
pub fn clone(allocator: Allocator, m: anytype) Allocator.Error!@TypeOf(m) {
    var copy_map = @TypeOf(m).init(allocator);
    errdefer copy_map.deinit();
    try copy_map.ensureTotalCapacity(m.count());
    var it = m.iterator();
    while (it.next()) |entry| {
        copy_map.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
    return copy_map;
}

/// Copy copies all key/value pairs in src adding them to dst.
/// When a key in src is already present in dst, the value in dst will be overwritten.
pub fn copy(dst: anytype, src: anytype) Allocator.Error!void {
    var it = src.iterator();
    while (it.next()) |entry| {
        try dst.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

/// Equal reports whether two maps contain the same key/value pairs.
/// Values are compared using `==`.
pub fn equal(m1: anytype, m2: anytype) bool {
    if (m1.count() != m2.count()) return false;
    var it = m1.iterator();
    while (it.next()) |entry| {
        const v2 = m2.get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.* != v2) return false;
    }
    return true;
}

/// EqualFunc reports whether two maps contain the same key/value pairs using eq to compare values.
pub fn equalFunc(m1: anytype, m2: anytype, eq_fn: anytype) bool {
    if (m1.count() != m2.count()) return false;
    var it = m1.iterator();
    while (it.next()) |entry| {
        const v2 = m2.get(entry.key_ptr.*) orelse return false;
        if (!eq_fn(entry.value_ptr.*, v2)) return false;
    }
    return true;
}

pub fn Key(comptime M: type) type {
    const T = if (@typeInfo(M) == .pointer) @typeInfo(M).pointer.child else M;
    const names = @typeInfo(T.KV).@"struct".field_names;
    const types = @typeInfo(T.KV).@"struct".field_types;
    inline for (names, types) |name, ty| {
        if (std.mem.eql(u8, name, "key")) return ty;
    }
    unreachable;
}

pub fn Value(comptime M: type) type {
    const T = if (@typeInfo(M) == .pointer) @typeInfo(M).pointer.child else M;
    const names = @typeInfo(T.KV).@"struct".field_names;
    const types = @typeInfo(T.KV).@"struct".field_types;
    inline for (names, types) |name, ty| {
        if (std.mem.eql(u8, name, "value")) return ty;
    }
    unreachable;
}

/// DeleteFunc deletes any key/value pairs in m for which del returns true.
pub fn deleteFunc(allocator: Allocator, m: anytype, del_fn: anytype) Allocator.Error!void {
    const K = Key(@TypeOf(m));
    var to_remove = std.ArrayList(K).empty;
    defer to_remove.deinit(allocator);

    var it = m.iterator();
    while (it.next()) |entry| {
        if (del_fn(entry.key_ptr.*, entry.value_ptr.*)) {
            try to_remove.append(allocator, entry.key_ptr.*);
        }
    }
    for (to_remove.items) |k| {
        _ = m.remove(k);
    }
}

/// Keys returns the keys of the map m in an allocated slice.
pub fn keys(allocator: Allocator, m: anytype) Allocator.Error![]Key(@TypeOf(m)) {
    const K = Key(@TypeOf(m));
    var list = try allocator.alloc(K, m.count());
    var it = m.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        list[idx] = entry.key_ptr.*;
    }
    return list;
}

/// Values returns the values of the map m in an allocated slice.
pub fn values(allocator: Allocator, m: anytype) Allocator.Error![]Value(@TypeOf(m)) {
    const V = Value(@TypeOf(m));
    var list = try allocator.alloc(V, m.count());
    var it = m.iterator();
    var idx: usize = 0;
    while (it.next()) |entry| : (idx += 1) {
        list[idx] = entry.value_ptr.*;
    }
    return list;
}

test "maps.clone and maps.equal" {
    const testing = std.testing;

    var m1 = std.AutoHashMap(i32, i32).init(testing.allocator);
    defer m1.deinit();
    try m1.put(1, 100);
    try m1.put(2, 200);
    try m1.put(3, 300);

    var m2 = try clone(testing.allocator, m1);
    defer m2.deinit();

    try testing.expect(equal(m1, m2));

    try m2.put(4, 400);
    try testing.expect(!equal(m1, m2));
}

test "maps.copy and maps.equalFunc" {
    const testing = std.testing;

    var dst = std.StringHashMap(i32).init(testing.allocator);
    defer dst.deinit();
    try dst.put("a", 1);

    var src = std.StringHashMap(i32).init(testing.allocator);
    defer src.deinit();
    try src.put("b", 2);
    try src.put("a", 10);

    try copy(&dst, src);
    try testing.expectEqual(@as(usize, 2), dst.count());
    try testing.expectEqual(@as(?i32, 10), dst.get("a"));
    try testing.expectEqual(@as(?i32, 2), dst.get("b"));

    const Eq = struct {
        fn cmp(v1: i32, v2: i32) bool {
            return @abs(v1 - v2) <= 10;
        }
    };
    try testing.expect(equalFunc(src, dst, Eq.cmp));
}

test "maps.keys, maps.values, and maps.deleteFunc" {
    const testing = std.testing;

    var m = std.AutoHashMap(u32, []const u8).init(testing.allocator);
    defer m.deinit();
    try m.put(10, "apple");
    try m.put(20, "banana");
    try m.put(30, "cherry");

    const k = try keys(testing.allocator, m);
    defer testing.allocator.free(k);
    try testing.expectEqual(@as(usize, 3), k.len);

    const v = try values(testing.allocator, m);
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, 3), v.len);

    const Del = struct {
        fn isBanana(_: u32, val: []const u8) bool {
            return std.mem.eql(u8, val, "banana");
        }
    };
    try deleteFunc(testing.allocator, &m, Del.isBanana);
    try testing.expectEqual(@as(usize, 2), m.count());
    try testing.expect(m.get(20) == null);
}
