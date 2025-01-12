const std = @import("std");
const dbus = @import("dbus.zig");
const Config = @import("config.zig").Config;

pub const PowerProfiles = struct {
    const PP_NAME = "org.freedesktop.UPower.PowerProfiles";
    const PP_PATH = "/org/freedesktop/UPower/PowerProfiles";
    const PP_IFACE = "org.freedesktop.UPower.PowerProfiles";

    allocator: std.mem.Allocator,
    dbus: dbus.DBus,
    config: *Config,
    original_profile: ?[]const u8,
    has_performance: bool,

    pub fn init(allocator: std.mem.Allocator, config: *Config) !*PowerProfiles {
        var self = try allocator.create(PowerProfiles);
        errdefer allocator.destroy(self);

        if (!config.enable_performance_mode) {
            std.log.info("Performance mode disabled in config", .{});
            self.* = .{
                .allocator = allocator,
                .dbus = undefined,
                .config = config,
                .original_profile = null,
                .has_performance = false,
            };
            return self;
        }

        self.* = .{
            .allocator = allocator,
            .dbus = dbus.DBus.init(allocator, PP_NAME, PP_PATH, PP_IFACE),
            .config = config,
            .original_profile = null,
            .has_performance = false,
        };

        const profiles = try self.getAvailableProfiles(allocator);
        defer {
            for (profiles) |profile| {
                allocator.free(profile);
            }
            allocator.free(profiles);
        }

        std.log.info("Available power profiles:", .{});
        for (profiles) |profile| {
            std.log.info("  - {s}", .{profile});
        }

        for (profiles) |profile| {
            if (std.mem.eql(u8, profile, "performance")) {
                self.has_performance = true;
                break;
            }
        }

        return self;
    }

    pub fn deinit(self: *PowerProfiles) void {
        if (self.original_profile) |profile| {
            self.allocator.free(profile);
        }
        self.allocator.destroy(self);
    }

    pub fn isPerformanceAvailable(self: *const PowerProfiles) bool {
        return self.has_performance;
    }

    pub fn getAvailableProfiles(self: *PowerProfiles, alloc: std.mem.Allocator) ![]const []const u8 {
        var result = std.ArrayList([]const u8).init(alloc);
        errdefer {
            for (result.items) |item| {
                alloc.free(item);
            }
            result.deinit();
        }

        const profiles_raw = try self.dbus.getPropertyArray("Profiles");
        defer {
            for (profiles_raw) |item| {
                alloc.free(item);
            }
            alloc.free(profiles_raw);
        }

        var i: usize = 0;
        while (i < profiles_raw.len) : (i += 1) {
            const item = profiles_raw[i];
            if (std.mem.eql(u8, item, "Profile")) {
                if (i + 2 < profiles_raw.len) {
                    try result.append(try alloc.dupe(u8, profiles_raw[i + 2]));
                }
            }
        }

        return result.toOwnedSlice();
    }

    pub fn enablePerformanceMode(self: *PowerProfiles) !void {
        if (!self.has_performance) {
            std.log.warn("Performance mode not available", .{});
            return;
        }

        if (self.original_profile == null) {
            self.original_profile = try self.dbus.getProperty("ActiveProfile");
        }

        try self.dbus.setProperty("ActiveProfile", "performance");
    }

    pub fn disablePerformanceMode(self: *PowerProfiles) !void {
        if (!self.has_performance) return;

        if (self.original_profile) |profile| {
            try self.dbus.setProperty("ActiveProfile", profile);
            self.allocator.free(profile);
            self.original_profile = null;
        }
    }
};
