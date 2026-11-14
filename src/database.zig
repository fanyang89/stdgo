pub const sql = @import("database/sql.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = sql;
}
