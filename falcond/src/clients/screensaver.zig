const std = @import("std");
const dbus = @import("dbus.zig");

pub const Screensaver = struct {
    const SS_NAME = "org.freedesktop.ScreenSaver";
    const SS_PATH = "/org/freedesktop/ScreenSaver";
    const SS_IFACE = "org.freedesktop.ScreenSaver";

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

    pub fn inhibit(self: *Screensaver, app_name: []const u8, reason: []const u8, uid: ?u32) !u32 {
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

    pub fn uninhibit(self: *Screensaver, cookie: u32, uid: ?u32) !void {
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
};
