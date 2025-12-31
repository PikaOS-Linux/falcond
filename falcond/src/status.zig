const std = @import("std");
const Config = @import("config/config.zig").Config;
const ProfileManager = @import("profile/manager.zig").ProfileManager;
const PowerProfiles = @import("clients/power_profiles.zig").PowerProfiles;

pub const StatusManager = struct {
    const status_dir = "/var/lib/falcond";
    const status_file = "/var/lib/falcond/status";

    pub fn update(
        allocator: std.mem.Allocator,
        config: Config,
        profile_manager: *const ProfileManager,
        power_profiles: ?*PowerProfiles,
    ) !void {
        _ = allocator;
        std.fs.makeDirAbsolute(status_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try std.fs.createFileAbsolute(status_file, .{ .mode = 0o644 });
        defer file.close();
        file.chmod(0o644) catch {};

        var writer_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&writer_buffer);
        const writer = &file_writer.interface;

        try writer.writeAll("FEATURES:\n");
        try writer.print("  Performance Mode: {s}\n", .{if (power_profiles != null and power_profiles.?.isPerformanceAvailable()) "Available" else "Unavailable"});
        try writer.writeAll("\n");

        try writer.writeAll("CONFIG:\n");
        try writer.print("  Profile Mode: {s}\n", .{@tagName(config.profile_mode)});
        try writer.print("  Global VCache Mode: {s}\n", .{@tagName(config.vcache_mode)});
        try writer.print("  Global SCX Scheduler: {s}\n", .{@tagName(config.scx_sched)});
        try writer.writeAll("\n");

        try writer.print("LOADED_PROFILES: {d}\n\n", .{profile_manager.profiles.items.len});

        try writer.writeAll("ACTIVE_PROFILE: ");
        if (profile_manager.active_profile) |profile| {
            try writer.print("{s}\n", .{profile.name});
        } else {
            try writer.writeAll("None\n");
        }
        try writer.writeAll("\n");

        try writer.writeAll("QUEUED_PROFILES:\n");
        if (profile_manager.queued_profiles.items.len > 0) {
            for (profile_manager.queued_profiles.items) |profile| {
                try writer.print("  - {s}\n", .{profile.name});
            }
        } else {
            try writer.writeAll("  (None)\n");
        }
        try writer.writeAll("\n");

        try writer.writeAll("CURRENT_STATUS:\n");

        if (power_profiles) |pp| {
            if (pp.isPerformanceAvailable()) {
                var perf_active = false;
                if (profile_manager.active_profile) |p| {
                    if (p.performance_mode) perf_active = true;
                }
                if (config.enable_performance_mode and perf_active) {
                    try writer.writeAll("  Performance Mode: Active\n");
                } else {
                    try writer.writeAll("  Performance Mode: Inactive\n");
                }
            } else {
                try writer.writeAll("  Performance Mode: Unsupported\n");
            }
        } else {
            try writer.writeAll("  Performance Mode: Disabled/Unavailable\n");
        }

        const effective_vcache = if (config.vcache_mode != .none) config.vcache_mode else if (profile_manager.active_profile) |p| p.vcache_mode else .none;
        try writer.print("  VCache Mode: {s}\n", .{@tagName(effective_vcache)});
        const effective_scx = if (config.scx_sched != .none) config.scx_sched else if (profile_manager.active_profile) |p| p.scx_sched else .none;
        try writer.print("  SCX Scheduler: {s}\n", .{@tagName(effective_scx)});

        try writer.writeAll("\n");
        try writer.flush();
    }
};
