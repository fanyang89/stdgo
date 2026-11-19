const backend = @import("backend.zig");

pub const Mutex = struct {
    locked: backend.Value(bool) = .init(false),

    pub fn lock(self: *Mutex) void {
        while (self.locked.swap(true, .acquire)) {
            backend.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.locked.store(false, .release);
    }

    pub fn tryLock(self: *Mutex) bool {
        return !self.locked.swap(true, .acquire);
    }
};
