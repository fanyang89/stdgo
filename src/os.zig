pub const exec = @import("os/exec.zig");
pub const file = @import("os/file.zig");
pub const env = @import("os/env.zig");
pub const user = @import("os/user.zig");
pub const proc = @import("os/proc.zig");

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
pub const rename = file.rename;
pub const truncate = file.truncate;
pub const symlink = file.symlink;
pub const readlink = file.readlink;
pub const chmod = file.chmod;
pub const isNotExist = file.isNotExist;
pub const isExist = file.isExist;
pub const isPermission = file.isPermission;
pub const stdin = file.stdin;
pub const stdout = file.stdout;
pub const stderr = file.stderr;

pub const getenv = env.getenv;
pub const lookupEnv = env.lookupEnv;
pub const environ = env.environ;

pub const getpid = proc.getpid;
pub const getppid = proc.getppid;
pub const hostname = proc.hostname;
pub const getwd = proc.getwd;
pub const executable = proc.executable;
pub const tempDir = proc.tempDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = exec;
    _ = file;
    _ = env;
    _ = user;
    _ = proc;
}
