const std = @import("std");
const dbus = @import("dbus.zig");

pub const Screensaver = struct {
    const SS_NAME = "org.freedesktop.ScreenSaver";
    const SS_PATH = "/org/freedesktop/ScreenSaver";
    const SS_IFACE = "org.freedesktop.ScreenSaver";

    pub const Cookie = struct {
        dbus_cookie: ?u32 = null,
        pid: ?i32 = null,
    };

    allocator: std.mem.Allocator,
    dbus: dbus.DBus,

    pub fn init(allocator: std.mem.Allocator) !*Screensaver {
        const self = try allocator.create(Screensaver);
        self.* = .{
            .allocator = allocator,
            .dbus = dbus.DBus.initSession(allocator, SS_NAME, SS_PATH, SS_IFACE),
        };
        return self;
    }

    pub fn deinit(self: *Screensaver) void {
        self.allocator.destroy(self);
    }

    pub fn inhibit(self: *Screensaver, app_name: []const u8, reason: []const u8, uid: ?u32) !Cookie {
        var cookie = Cookie{};
        var any_success = false;

        // Try DBus
        if (self.inhibitDBus(app_name, reason, uid)) |c| {
            cookie.dbus_cookie = c;
            any_success = true;
        } else |err| {
            std.log.warn("DBus ScreenSaver inhibit failed: {s}", .{@errorName(err)});
        }

        // Try systemd-inhibit
        if (self.inhibitLogin1(app_name, reason)) |pid| {
            cookie.pid = pid;
            any_success = true;
        } else |err| {
            std.log.warn("Login1 inhibit failed: {s}", .{@errorName(err)});
        }

        if (!any_success) {
            return error.AllInhibitMethodsFailed;
        }

        return cookie;
    }

    fn inhibitDBus(self: *Screensaver, app_name: []const u8, reason: []const u8, uid: ?u32) !u32 {
        const args = [_][]const u8{
            "ss",
            app_name,
            reason,
        };

        const dbus_inst = self.dbus.withUser(uid);
        const output = try dbus_inst.callMethod("Inhibit", &args);
        defer self.allocator.free(output);

        // Output format: "u 123"
        const trimmed = std.mem.trim(u8, output, " \n\r\t");
        var it = std.mem.splitScalar(u8, trimmed, ' ');
        _ = it.next(); // Skip type "u"

        if (it.next()) |value_str| {
            return std.fmt.parseInt(u32, value_str, 10);
        }

        return error.ParseError;
    }

    fn inhibitLogin1(self: *Screensaver, app_name: []const u8, reason: []const u8) !i32 {
        if (!try self.checkSystemdInhibit()) {
            return error.SystemdInhibitNotFound;
        }

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

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        return child.id;
    }

    pub fn uninhibit(self: *Screensaver, cookie: Cookie, uid: ?u32) !void {
        if (cookie.dbus_cookie) |c| {
            self.uninhibitDBus(c, uid) catch |err| {
                std.log.warn("Failed to uninhibit DBus: {s}", .{@errorName(err)});
            };
        }
        if (cookie.pid) |p| {
            self.uninhibitLogin1(p) catch |err| {
                std.log.warn("Failed to uninhibit Login1: {s}", .{@errorName(err)});
            };
        }
    }

    fn uninhibitDBus(self: *Screensaver, cookie: u32, uid: ?u32) !void {
        var buf: [32]u8 = undefined;
        const cookie_str = try std.fmt.bufPrint(&buf, "{d}", .{cookie});

        const args = [_][]const u8{
            "u",
            cookie_str,
        };

        const dbus_inst = self.dbus.withUser(uid);
        const output = try dbus_inst.callMethod("UnInhibit", &args);
        defer self.allocator.free(output);
    }

    fn uninhibitLogin1(self: *Screensaver, pid: i32) !void {
        _ = self;
        std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
            if (err == error.ProcessNotFound) {
                // Already dead, that's fine
                return;
            }
            return err;
        };

        _ = std.posix.waitpid(pid, 0);
    }

    fn checkSystemdInhibit(self: *Screensaver) !bool {
        const argv = [_][]const u8{
            "which",
            "systemd-inhibit",
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const result = try child.spawnAndWait();
        return result.Exited == 0;
    }
};
