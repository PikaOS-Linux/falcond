const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.scanner);

// ---------------------------------------------------------------------------
// PID digit detection
// ---------------------------------------------------------------------------

const v_size = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(v_size, u8);

fn isAllDigits(name: [*]const u8, len: usize) bool {
    if (len == 0 or len > v_size) return false;
    var buf: [v_size]u8 = @splat('0'); // pad with valid digit
    @memcpy(buf[0..len], name[0..len]);
    const v: Vec = buf;
    const ge_0 = v >= @as(Vec, @splat('0'));
    const le_9 = v <= @as(Vec, @splat('9'));
    const valid = ge_0 & le_9;
    return @reduce(.And, valid);
}

// ---------------------------------------------------------------------------
// PID parsing
// ---------------------------------------------------------------------------

fn parsePid(name: [*]const u8, len: usize) u32 {
    var result: u32 = 0;
    for (name[0..len]) |c| {
        result = result * 10 + @as(u32, c - '0');
    }
    return result;
}

// ---------------------------------------------------------------------------
// getProcessComm — read /proc/{pid}/comm (kernel-cached, max 16 bytes)
// ---------------------------------------------------------------------------

/// Fast process name from the kernel's task_struct via raw syscalls.
/// 3 syscalls (openat + read + close) with no Zig std wrappers.
pub fn getProcessComm(pid: u32) ?[16]u8 {
    // Build null-terminated relative path "PID/comm\0" for openat
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/comm", .{pid}) catch return null;
    path_buf[path.len] = 0;

    const fd = linux.openat(proc_dir_fd, @ptrCast(path_buf[0 .. path.len + 1]), .{}, 0);
    if (fd > std.math.maxInt(i32)) return null;
    defer _ = linux.close(@intCast(fd));

    var buf: [16]u8 = .{0} ** 16;
    const n = linux.read(@intCast(fd), &buf, 16);
    if (n == 0 or n > 16) return null;
    // Strip trailing newline
    if (buf[@intCast(n - 1)] == '\n') buf[@intCast(n - 1)] = 0;
    return buf;
}

/// Cached fd for /proc, opened once at startup. Used by getProcessComm
/// for openat() to avoid full path resolution on every call.
var proc_dir_fd: linux.fd_t = 0;

pub fn initProcFd() void {
    const fd = linux.openat(linux.AT.FDCWD, "/proc", .{ .DIRECTORY = true }, 0);
    if (fd > std.math.maxInt(i32)) {
        log.err("failed to open /proc", .{});
        return;
    }
    proc_dir_fd = @intCast(fd);
}

pub fn deinitProcFd() void {
    if (proc_dir_fd > 0) {
        _ = linux.close(proc_dir_fd);
        proc_dir_fd = 0;
    }
}

// ---------------------------------------------------------------------------
// getProcessName — read /proc/{pid}/cmdline and extract basename
// ---------------------------------------------------------------------------

pub fn getProcessName(allocator: std.mem.Allocator, pid: u32) ?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/cmdline", .{pid}) catch return null;
    path_buf[path.len] = 0;

    const fd = linux.openat(proc_dir_fd, @ptrCast(path_buf[0 .. path.len + 1]), .{}, 0);
    if (fd > std.math.maxInt(i32)) return null;
    defer _ = linux.close(@intCast(fd));

    var buffer: [512]u8 = undefined;
    const bytes = linux.read(@intCast(fd), &buffer, buffer.len);
    if (bytes == 0 or bytes > buffer.len) return null;

    const end = std.mem.indexOfScalar(u8, buffer[0..bytes], 0) orelse bytes;
    const cmdline = buffer[0..end];

    // Handle both Unix and Windows path separators (Wine/Proton)
    const last_unix = std.mem.lastIndexOfScalar(u8, cmdline, '/');
    const last_windows = std.mem.lastIndexOfScalar(u8, cmdline, '\\');
    const last_sep: ?usize = if (last_unix != null and last_windows != null)
        @max(last_unix.?, last_windows.?)
    else
        last_unix orelse last_windows;

    const exe_name = if (last_sep) |sep|
        cmdline[sep + 1 ..]
    else
        cmdline;

    return allocator.dupe(u8, exe_name) catch null;
}

// ---------------------------------------------------------------------------
// scanProcesses — enumerate running processes from /proc
// ---------------------------------------------------------------------------

/// Enumerate running processes from /proc. Values are heap-allocated strings —
/// use an arena allocator to avoid needing to free them individually.
pub fn scanProcesses(allocator: std.mem.Allocator) !std.AutoHashMap(u32, []const u8) {
    var pids = std.AutoHashMap(u32, []const u8).init(allocator);

    // Reuse cached proc_dir_fd; seek to start for a fresh directory read
    _ = linux.lseek(proc_dir_fd, 0, linux.SEEK.SET);

    var buffer: [8192]u8 = undefined;
    while (true) {
        const rc = linux.syscall3(.getdents64, @as(usize, @intCast(proc_dir_fd)), @intFromPtr(&buffer), buffer.len);

        // syscall returns usize; errors are encoded as high values (> maxInt - 4096)
        if (rc > std.math.maxInt(usize) - 4096) return error.ReadDirError;
        if (rc == 0) break;
        const nread = rc;

        var pos: usize = 0;
        while (pos < nread) {
            const dirent = @as(*align(1) linux.dirent64, @ptrCast(&buffer[pos]));
            if (dirent.type == linux.DT.DIR) {
                const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&dirent.name)), 0);
                if (isAllDigits(name.ptr, name.len)) {
                    const pid = parsePid(name.ptr, name.len);
                    if (getProcessName(allocator, pid)) |proc_name| {
                        try pids.put(pid, proc_name);
                    }
                }
            }
            pos += dirent.reclen;
        }
    }

    return pids;
}

// ---------------------------------------------------------------------------
// isExe — check for .exe suffix (Wine/Proton executables)
// ---------------------------------------------------------------------------

pub fn isExe(name: []const u8) bool {
    if (name.len < 4) return false;
    const suffix: *const [4]u8 = @ptrCast(name.ptr + name.len - 4);
    // OR 0x20 lowercases ASCII letters; '.' (0x2E) is unaffected
    const lower = [4]u8{
        suffix[0] | 0x20,
        suffix[1] | 0x20,
        suffix[2] | 0x20,
        suffix[3] | 0x20,
    };
    const target = [4]u8{ '.', 'e', 'x', 'e' };
    return @as(u32, @bitCast(lower)) == @as(u32, @bitCast(target));
}

// ---------------------------------------------------------------------------
// isProtonParent — walk parent chain looking for proton/wine/reaper
// ---------------------------------------------------------------------------

pub fn isProtonParent(pid: u32) !bool {
    var current_pid = pid;

    // Walk up to 10 parent levels
    for (0..10) |_| {
        if (current_pid <= 1) return false;

        // Open /proc/{pid}/status via openat on cached proc_dir_fd
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/status", .{current_pid}) catch return false;
        path_buf[path.len] = 0;

        const fd = linux.openat(proc_dir_fd, @ptrCast(path_buf[0 .. path.len + 1]), .{}, 0);
        if (fd > std.math.maxInt(i32)) return false;

        var content_buf: [256]u8 = undefined;
        const n = linux.read(@intCast(fd), &content_buf, content_buf.len);
        _ = linux.close(@intCast(fd));

        if (n == 0 or n > content_buf.len) return false;
        const content = content_buf[0..@intCast(n)];

        const ppid_line = std.mem.indexOf(u8, content, "PPid:") orelse return false;
        const line_end = std.mem.indexOfScalarPos(u8, content, ppid_line, '\n') orelse content.len;
        const ppid_start = ppid_line + 5; // Length of "PPid:"
        const ppid_str = std.mem.trim(u8, content[ppid_start..line_end], " \t");

        const ppid = std.fmt.parseInt(u32, ppid_str, 10) catch return false;
        if (ppid <= 1) return false;

        // Use getProcessComm (kernel-cached, no heap alloc) instead of getProcessName
        if (getProcessComm(ppid)) |comm_buf| {
            const comm = std.mem.sliceTo(&comm_buf, 0);

            if (std.mem.indexOf(u8, comm, "proton") != null or
                std.mem.indexOf(u8, comm, "wine") != null or
                std.mem.indexOf(u8, comm, "reaper") != null)
            {
                return true;
            }
        }

        current_pid = ppid;
    }

    return false;
}

// ---------------------------------------------------------------------------
// findUserForProcess — read UID from /proc/PID/status
// ---------------------------------------------------------------------------

pub fn findUserForProcess(pid: u32) ?u32 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/status", .{pid}) catch return null;
    path_buf[path.len] = 0;

    const fd = linux.openat(proc_dir_fd, @ptrCast(path_buf[0 .. path.len + 1]), .{}, 0);
    if (fd > std.math.maxInt(i32)) return null;
    defer _ = linux.close(@intCast(fd));

    var content_buf: [256]u8 = undefined;
    const n = linux.read(@intCast(fd), &content_buf, content_buf.len);
    if (n == 0 or n > content_buf.len) return null;
    const content = content_buf[0..@intCast(n)];

    const uid_line = std.mem.indexOf(u8, content, "Uid:") orelse return null;
    const line_end = std.mem.indexOfScalarPos(u8, content, uid_line, '\n') orelse content.len;
    const uid_start = uid_line + 4; // Length of "Uid:"
    const uid_str = std.mem.trim(u8, content[uid_start..line_end], " \t");

    // Format: "Uid: real effective saved fs" — we want the real UID
    var iter = std.mem.tokenizeAny(u8, uid_str, " \t");
    const real_uid_str = iter.next() orelse return null;

    return std.fmt.parseInt(u32, real_uid_str, 10) catch null;
}

// ===========================================================================
// Tests
// ===========================================================================

test "isAllDigits" {
    const digits = "12345";
    try std.testing.expect(isAllDigits(digits.ptr, digits.len));

    const mixed = "123ab";
    try std.testing.expect(!isAllDigits(mixed.ptr, mixed.len));

    // Empty string should fail
    try std.testing.expect(!isAllDigits("".ptr, 0));

    const single = "7";
    try std.testing.expect(isAllDigits(single.ptr, single.len));

    const all_nines = "999999";
    try std.testing.expect(isAllDigits(all_nines.ptr, all_nines.len));

    const with_dot = "123.45";
    try std.testing.expect(!isAllDigits(with_dot.ptr, with_dot.len));
}

test "parsePid" {
    const p1 = "1";
    try std.testing.expectEqual(@as(u32, 1), parsePid(p1.ptr, p1.len));

    const p2 = "12345";
    try std.testing.expectEqual(@as(u32, 12345), parsePid(p2.ptr, p2.len));

    const p3 = "999999";
    try std.testing.expectEqual(@as(u32, 999999), parsePid(p3.ptr, p3.len));

    const p4 = "42";
    try std.testing.expectEqual(@as(u32, 42), parsePid(p4.ptr, p4.len));
}

test "isExe" {
    // .exe files should pass
    try std.testing.expect(isExe("game.exe"));
    try std.testing.expect(isExe("C:\\Program Files\\game.exe"));
    try std.testing.expect(isExe(".exe"));

    // Case-insensitive
    try std.testing.expect(isExe("game.EXE"));
    try std.testing.expect(isExe("game.Exe"));
    try std.testing.expect(isExe("game.eXe"));

    // Non-.exe files should fail
    try std.testing.expect(!isExe("game.bin"));
    try std.testing.expect(!isExe("game"));
    try std.testing.expect(!isExe("exefile"));

    // Edge cases
    try std.testing.expect(!isExe(""));
    try std.testing.expect(!isExe("exe"));
    try std.testing.expect(!isExe("a.ex"));
}
