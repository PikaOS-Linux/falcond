const std = @import("std");

pub const cgroup_root = "/sys/fs/cgroup";
pub const max_child_name_len = 96;

pub fn parseUnifiedCgroupPath(content: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.startsWith(u8, line, "0::")) {
            const path = line[3..];
            if (path.len == 0 or path[0] != '/') return error.InvalidCgroupPath;
            validateCgroupPath(path) catch return error.InvalidCgroupPath;
            return path;
        }
    }
    return error.NoUnifiedCgroup;
}

pub fn sanitizeProfileName(buf: []u8, name: []const u8) []const u8 {
    const out_len = @min(buf.len, @min(name.len, max_child_name_len));
    for (name[0..out_len], 0..) |c, i| {
        buf[i] = if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') c else '_';
    }
    return buf[0..out_len];
}

pub fn canonicalizeSourcePath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "falcond-dmem-other") or std.mem.startsWith(u8, base, "falcond-dmem-p")) {
        return std.fs.path.dirname(path) orelse path;
    }
    return path;
}

pub fn cgroupFsPathFromUnified(allocator: std.mem.Allocator, relative: []const u8) ![]const u8 {
    validateCgroupPath(relative) catch return error.InvalidCgroupPath;
    const clean_relative = if (std.mem.startsWith(u8, relative, "/")) relative[1..] else relative;
    if (clean_relative.len == 0) return try allocator.dupe(u8, cgroup_root);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cgroup_root, clean_relative });
}

fn validateCgroupPath(path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidCgroupPath;
    }
}

test "parse unified cgroup path" {
    const parsed = try parseUnifiedCgroupPath(
        \\12:cpu:/not-v2
        \\0::/user.slice/app.scope
    );

    try std.testing.expectEqualStrings("/user.slice/app.scope", parsed);
    try std.testing.expectError(error.NoUnifiedCgroup, parseUnifiedCgroupPath("12:cpu:/not-v2\n"));
}

test "convert unified cgroup path to cgroupfs path" {
    const root = try cgroupFsPathFromUnified(std.testing.allocator, "/");
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings("/sys/fs/cgroup", root);

    const scoped = try cgroupFsPathFromUnified(std.testing.allocator, "/user.slice/app.scope");
    defer std.testing.allocator.free(scoped);
    try std.testing.expectEqualStrings("/sys/fs/cgroup/user.slice/app.scope", scoped);
}

test "sanitize profile names and canonicalize managed child paths" {
    var buf: [128]u8 = undefined;
    const child = sanitizeProfileName(&buf, "Cyber punk/2077.exe:*");
    try std.testing.expectEqualStrings("Cyber_punk_2077.exe__", child);

    const managed = canonicalizeSourcePath("/sys/fs/cgroup/a/b/falcond-dmem-p07-Cyberpunk2077.exe");
    try std.testing.expectEqualStrings("/sys/fs/cgroup/a/b", managed);

    const unchanged = canonicalizeSourcePath("/sys/fs/cgroup/a/b/app.scope");
    try std.testing.expectEqualStrings("/sys/fs/cgroup/a/b/app.scope", unchanged);
}
