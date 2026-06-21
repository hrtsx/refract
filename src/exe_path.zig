const std = @import("std");
const builtin = @import("builtin");

const macos_exe = struct {
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
};

/// Path to the running executable, written into `buf`. Returns a slice of `buf`
/// or null on failure. Cross-platform: macOS `_NSGetExecutablePath`, otherwise
/// the Linux `/proc/self/exe` symlink.
pub fn selfExePath(buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        var len: u32 = @intCast(buf.len);
        if (macos_exe._NSGetExecutablePath(buf.ptr, &len) == 0) {
            const slen = std.mem.indexOfScalar(u8, buf[0..@min(buf.len, len)], 0) orelse @as(usize, @intCast(len));
            return buf[0..slen];
        }
        return null;
    }
    const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
    if (n > 0 and n < buf.len) return buf[0..@intCast(n)];
    return null;
}
