const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.scanner);
const proton_parent_comm_needles = [_][]const u8{
    "wine",
    "reaper",
    "umu-run",
};

// ---------------------------------------------------------------------------
// PID digit detection
// ---------------------------------------------------------------------------

const v_size = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(v_size, u8);

fn isAllDigits(name: [*]const u8, len: usize) bool {
    if (len == 0 or len > v_size) return false;
    var buf: [v_size]u8 = @splat('0');
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

pub fn getProcessComm(pid: u32) ?[16]u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/comm", .{pid}) catch return null;
    const fd = posix.openat(proc_dir_fd, path, .{}, 0) catch return null;
    defer _ = posix.system.close(fd);

    var buf: [16]u8 = .{0} ** 16;
    const n = posix.read(fd, &buf) catch return null;
    if (n == 0 or n > 16) return null;
    if (buf[@intCast(n - 1)] == '\n') buf[@intCast(n - 1)] = 0;
    return buf;
}

var proc_dir_fd: posix.fd_t = 0;

pub fn initProcFd() void {
    const fd = posix.openat(posix.AT.FDCWD, "/proc", .{ .DIRECTORY = true }, 0) catch {
        log.err("failed to open /proc", .{});
        return;
    };
    proc_dir_fd = fd;
}

pub fn deinitProcFd() void {
    if (proc_dir_fd > 0) {
        _ = posix.system.close(proc_dir_fd);
        proc_dir_fd = 0;
    }
}

// ---------------------------------------------------------------------------
// getProcessName — read /proc/{pid}/cmdline and extract best executable name
// ---------------------------------------------------------------------------

fn basenameFromPath(path: []const u8) []const u8 {
    const last_unix = std.mem.lastIndexOfScalar(u8, path, '/');
    const last_windows = std.mem.lastIndexOfScalar(u8, path, '\\');
    const last_sep: ?usize = if (last_unix != null and last_windows != null)
        @max(last_unix.?, last_windows.?)
    else
        last_unix orelse last_windows;

    return if (last_sep) |sep|
        path[sep + 1 ..]
    else
        path;
}

fn selectProcessNameFromCmdline(cmdline_buf: []const u8) []const u8 {
    var fallback: []const u8 = "";
    var it = std.mem.splitScalar(u8, cmdline_buf, 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        const base = basenameFromPath(arg);
        if (base.len == 0) continue;
        if (fallback.len == 0) {
            fallback = base;
        }
        if (isExe(base)) {
            return base;
        }
    }
    return fallback;
}

pub fn getProcessName(allocator: std.mem.Allocator, pid: u32) ?[]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/cmdline", .{pid}) catch return null;
    const fd = posix.openat(proc_dir_fd, path, .{}, 0) catch return null;
    defer _ = posix.system.close(fd);

    var buffer: [4096]u8 = undefined;
    const bytes = posix.read(fd, &buffer) catch return null;
    if (bytes == 0 or bytes > buffer.len) return null;

    const name = selectProcessNameFromCmdline(buffer[0..bytes]);
    if (name.len == 0) return null;

    return allocator.dupe(u8, name) catch null;
}

// ---------------------------------------------------------------------------
// scanProcesses — enumerate running processes from /proc
// ---------------------------------------------------------------------------

pub fn scanProcesses(allocator: std.mem.Allocator) !std.AutoHashMap(u32, []const u8) {
    var pids = std.AutoHashMap(u32, []const u8).init(allocator);

    _ = posix.system.lseek(proc_dir_fd, 0, posix.SEEK.SET);

    var buffer: [8192]u8 = undefined;
    while (true) {
        const rc = linux.syscall3(.getdents64, @as(usize, @intCast(proc_dir_fd)), @intFromPtr(&buffer), buffer.len);

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

    for (0..10) |_| {
        if (current_pid <= 1) return false;
        const ppid = readParentPid(current_pid) orelse return false;
        if (ppid <= 1) return false;
        if (isProtonProcess(ppid)) return true;
        current_pid = ppid;
    }

    return false;
}

fn readParentPid(pid: u32) ?u32 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/status", .{pid}) catch return null;
    const fd = posix.openat(proc_dir_fd, path, .{}, 0) catch return null;
    defer _ = posix.system.close(fd);

    var content_buf: [1024]u8 = undefined;
    const n = posix.read(fd, &content_buf) catch return null;
    if (n == 0 or n > content_buf.len) return null;
    const content = content_buf[0..@intCast(n)];

    const ppid_line = std.mem.indexOf(u8, content, "PPid:") orelse return null;
    const line_end = std.mem.indexOfScalarPos(u8, content, ppid_line, '\n') orelse content.len;
    const ppid_start = ppid_line + 5;
    const ppid_str = std.mem.trim(u8, content[ppid_start..line_end], " \t");
    return std.fmt.parseInt(u32, ppid_str, 10) catch null;
}

fn isProtonProcess(pid: u32) bool {
    if (getProcessComm(pid)) |comm_buf| {
        const comm = std.mem.sliceTo(&comm_buf, 0);
        inline for (proton_parent_comm_needles) |needle| {
            if (std.mem.indexOf(u8, comm, needle) != null) return true;
        }
    }

    return getCmdlineSubstringMatch(pid, "proton");
}

fn getCmdlineSubstringMatch(pid: u32, needle: []const u8) bool {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/cmdline", .{pid}) catch return false;
    const fd = posix.openat(proc_dir_fd, path, .{}, 0) catch return false;
    defer _ = posix.system.close(fd);

    var buf: [4096]u8 = undefined;
    const bytes = posix.read(fd, &buf) catch return false;
    if (bytes == 0 or bytes > buf.len) return false;

    return std.mem.indexOf(u8, buf[0..@intCast(bytes)], needle) != null;
}

// ---------------------------------------------------------------------------
// findUserForProcess — read UID from /proc/PID/status
// ---------------------------------------------------------------------------

pub fn findUserForProcess(pid: u32) ?u32 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{d}/status", .{pid}) catch return null;
    const fd = posix.openat(proc_dir_fd, path, .{}, 0) catch return null;
    defer _ = posix.system.close(fd);

    var content_buf: [1024]u8 = undefined;
    const n = posix.read(fd, &content_buf) catch return null;
    if (n == 0 or n > content_buf.len) return null;
    const content = content_buf[0..@intCast(n)];

    const uid_line = std.mem.indexOf(u8, content, "Uid:") orelse return null;
    const line_end = std.mem.indexOfScalarPos(u8, content, uid_line, '\n') orelse content.len;
    const uid_start = uid_line + 4;
    const uid_str = std.mem.trim(u8, content[uid_start..line_end], " \t");

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
    try std.testing.expect(isExe("game.exe"));
    try std.testing.expect(isExe("C:\\Program Files\\game.exe"));
    try std.testing.expect(isExe(".exe"));

    try std.testing.expect(isExe("game.EXE"));
    try std.testing.expect(isExe("game.Exe"));
    try std.testing.expect(isExe("game.eXe"));

    try std.testing.expect(!isExe("game.bin"));
    try std.testing.expect(!isExe("game"));
    try std.testing.expect(!isExe("exefile"));

    try std.testing.expect(!isExe(""));
    try std.testing.expect(!isExe("exe"));
    try std.testing.expect(!isExe("a.ex"));
}

test "selectProcessNameFromCmdline prefers later windows exe over argv0" {
    const cmdline = "/usr/bin/wine64\x00C:\\Program Files\\Cyberpunk 2077\\bin\\x64\\Cyberpunk2077.exe\x00--fullscreen\x00";
    try std.testing.expectEqualStrings("Cyberpunk2077.exe", selectProcessNameFromCmdline(cmdline));
}

test "selectProcessNameFromCmdline falls back to argv0 basename" {
    const cmdline = "/usr/bin/umu-run\x00--gameid\x001234\x00";
    try std.testing.expectEqualStrings("umu-run", selectProcessNameFromCmdline(cmdline));
}

test "basenameFromPath handles unix and windows separators" {
    try std.testing.expectEqualStrings("Cyberpunk2077.exe", basenameFromPath("S:\\common\\Cyberpunk 2077\\bin\\x64\\Cyberpunk2077.exe"));
    try std.testing.expectEqualStrings("proton", basenameFromPath("/usr/bin/proton"));
}
