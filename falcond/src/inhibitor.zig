//! Idle inhibitor with busctl D-Bus + systemd-inhibit fallback.
//!
//! Uses busctl to call org.freedesktop.ScreenSaver.Inhibit on the
//! target user's session bus (via sudo when running as root),
//! with systemd-inhibit as a fallback.

const std = @import("std");
const posix = std.posix;
const otter_utils = @import("otter_utils");
const scanner = @import("scanner.zig");
const log = std.log.scoped(.inhibitor);

const Self = @This();

allocator: std.mem.Allocator,
dbus_cookie: ?u32 = null,
target_uid: ?u32 = null,
systemd_pid: ?posix.pid_t = null,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.uninhibit();
}

pub fn inhibit(self: *Self, app_name: []const u8, reason: []const u8, pid: u32) void {
    var any_success = false;

    if (self.target_uid == null and pid != 0) {
        self.target_uid = scanner.findUserForProcess(pid);
    }

    if (self.dbus_cookie == null) {
        if (self.inhibitDBus(app_name, reason)) |cookie| {
            self.dbus_cookie = cookie;
            any_success = true;
        } else |err| {
            log.warn("busctl screensaver inhibit failed: {}", .{err});
        }
    } else {
        any_success = true;
    }

    if (self.systemd_pid == null) {
        self.inhibitLogin1(app_name, reason) catch |err| {
            log.warn("systemd-inhibit fallback failed: {}", .{err});
        };
        if (self.systemd_pid != null) {
            any_success = true;
        }
    }

    if (!any_success) {
        log.warn("all inhibit methods failed", .{});
    }
}

pub fn uninhibit(self: *Self) void {
    if (self.dbus_cookie) |cookie| {
        self.uninhibitDBus(cookie) catch |err| {
            log.warn("busctl screensaver uninhibit failed: {}", .{err});
        };
        self.dbus_cookie = null;
    }

    if (self.systemd_pid) |pid| {
        // SIGKILL because SIGTERM is blocked (inherited from signalfd mask)
        posix.kill(pid, posix.SIG.KILL) catch |err| {
            if (err != error.ProcessNotFound) {
                log.warn("failed to kill systemd-inhibit pid {d}: {}", .{ pid, err });
            }
        };
        var status: c_int = 0;
        _ = std.posix.system.waitpid(pid, &status, 0);
        self.systemd_pid = null;
    }

    self.target_uid = null;
}

pub fn isInhibited(self: *const Self) bool {
    return self.dbus_cookie != null or self.systemd_pid != null;
}

// ── D-Bus via busctl ────────────────────────────────────────────────────

fn inhibitDBus(self: *Self, app_name: []const u8, reason: []const u8) !u32 {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;

    // Root can't access user session bus directly, so use sudo
    if (posix.system.geteuid() == 0) {
        const uid = self.target_uid orelse return error.NoTargetUser;
        try argv.append(alloc, "sudo");
        try argv.append(alloc, "-u");
        try argv.append(alloc, try std.fmt.allocPrint(alloc, "#{d}", .{uid}));
        try argv.append(alloc, "env");
        try argv.append(alloc, try std.fmt.allocPrint(
            alloc,
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus",
            .{uid},
        ));
    }

    try argv.appendSlice(alloc, &.{
        "busctl",
        "--user",
        "call",
        "org.freedesktop.ScreenSaver",
        "/org/freedesktop/ScreenSaver",
        "org.freedesktop.ScreenSaver",
        "Inhibit",
        "ss",
        app_name,
        reason,
    });

    const result = try std.process.run(self.allocator, otter_utils.io.get(), .{
        .argv = argv.items,
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        log.warn("busctl inhibit exited with {}", .{result.term});
        return error.CommandFailed;
    }

    const stdout = std.mem.trim(u8, result.stdout, " \n\r\t");
    const cookie = parseBusctlUint(stdout) orelse {
        log.warn("failed to parse inhibit cookie from: '{s}'", .{stdout});
        return error.ParseError;
    };

    log.info("screensaver inhibited (cookie={d}, uid={?})", .{ cookie, self.target_uid });
    return cookie;
}

fn uninhibitDBus(self: *Self, cookie: u32) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;

    if (posix.system.geteuid() == 0) {
        const uid = self.target_uid orelse return error.NoTargetUser;
        try argv.append(alloc, "sudo");
        try argv.append(alloc, "-u");
        try argv.append(alloc, try std.fmt.allocPrint(alloc, "#{d}", .{uid}));
        try argv.append(alloc, "env");
        try argv.append(alloc, try std.fmt.allocPrint(
            alloc,
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus",
            .{uid},
        ));
    }

    const cookie_str = try std.fmt.allocPrint(alloc, "{d}", .{cookie});

    try argv.appendSlice(alloc, &.{
        "busctl",
        "--user",
        "call",
        "org.freedesktop.ScreenSaver",
        "/org/freedesktop/ScreenSaver",
        "org.freedesktop.ScreenSaver",
        "UnInhibit",
        "u",
        cookie_str,
    });

    const result = try std.process.run(self.allocator, otter_utils.io.get(), .{
        .argv = argv.items,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(256),
    });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        log.warn("busctl uninhibit exited with {}", .{result.term});
        return error.CommandFailed;
    }

    log.info("screensaver uninhibited (cookie {d})", .{cookie});
}

// ── systemd-inhibit fallback ────────────────────────────────────────────

fn inhibitLogin1(self: *Self, app_name: []const u8, reason: []const u8) !void {
    const who_arg = try std.fmt.allocPrint(self.allocator, "--who={s}", .{app_name});
    defer self.allocator.free(who_arg);

    const why_arg = try std.fmt.allocPrint(self.allocator, "--why={s}", .{reason});
    defer self.allocator.free(why_arg);

    const argv = [_][]const u8{
        "systemd-inhibit",
        "--what=idle",
        who_arg,
        why_arg,
        "--mode=block",
        "sleep",
        "infinity",
    };

    const child = try std.process.spawn(otter_utils.io.get(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    self.systemd_pid = child.id;
    log.info("started systemd-inhibit (pid {?d})", .{child.id});
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Parse busctl's "u <cookie>" response format.
fn parseBusctlUint(output: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, output, "u ");
    const end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    return std.fmt.parseInt(u32, trimmed[0..end], 10) catch null;
}
