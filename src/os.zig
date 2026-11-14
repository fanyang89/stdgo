pub const exec = @import("os/exec.zig");
pub const file = @import("os/file.zig");
pub const env = @import("os/env.zig");

// Direct aliases matching Go os package
pub const File = file.File;
pub const FileInfo = file.FileInfo;
pub const DirEntry = file.DirEntry;

pub const open = file.open;
pub const create = file.create;
pub const readFile = file.readFile;
pub const writeFile = file.writeFile;
pub const mkdir = file.mkdir;
pub const mkdirAll = file.mkdirAll;
pub const remove = file.remove;
pub const removeAll = file.removeAll;
pub const stat = file.stat;
pub const readDir = file.readDir;

pub const getenv = env.getenv;
pub const lookupEnv = env.lookupEnv;
pub const environ = env.environ;

test {
    @import("std").testing.refAllDecls(@This());
    _ = exec;
    _ = file;
    _ = env;
}
