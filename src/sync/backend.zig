const std = @import("std");
const root = @import("root");

// Scenario executables can replace scheduling points without duplicating algorithms.
const backend = if (@hasDecl(root, "stdgo_sync_backend")) root.stdgo_sync_backend else struct {
    pub const Value = std.atomic.Value;
    pub const Thread = std.Thread;
};
pub const Value = backend.Value;
pub const Thread = backend.Thread;
