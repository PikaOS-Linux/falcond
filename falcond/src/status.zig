const std = @import("std");
const Config = @import("config/config.zig").Config;
const ProfileManager = @import("profile/manager.zig").ProfileManager;
const PowerProfiles = @import("clients/power_profiles.zig").PowerProfiles;

pub const StatusManager = struct {
    const status_dir = "/var/lib/falcond";
    const status_file = "/var/lib/falcond/status";
    const tmp_status_file = "/tmp/falcond_status";

    pub fn update(
        allocator: std.mem.Allocator,
        config: Config,
        profile_manager: *const ProfileManager,
        power_profiles: ?*PowerProfiles,
    ) !void {
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(allocator);
        const writer = buffer.writer(allocator);

        try writer.writeAll("FEATURES:\n");
        try writer.print("  Performance Mode: {s}\n", .{if (power_profiles != null and power_profiles.?.isPerformanceAvailable()) "Available" else "Unavailable"});
        try writer.writeAll("\n");

        try writer.writeAll("CONFIG:\n");
        try writer.print("  Profile Mode: {s}\n", .{@tagName(config.profile_mode)});
        try writer.print("  Global VCache Mode: {s}\n", .{@tagName(config.vcache_mode)});
        try writer.print("  Global SCX Scheduler: {s}\n", .{@tagName(config.scx_sched)});
        try writer.writeAll("\n");

        try writer.writeAll("AVAILABLE_SCX_SCHEDULERS:\n");
        const sched_list = @import("clients/scx_scheds.zig").getSupportedSchedulersList();
        if (sched_list.len > 0) {
            for (sched_list) |sched| {
                try writer.print("  - {s}\n", .{sched.toScxName()});
            }
        } else {
            try writer.writeAll("  (None or scx_loader unavailable)\n");
        }
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

        if (profile_manager.active_profile) |_| {
            try writer.writeAll("RESTORE_STATE:\n");

            // SCX Restore State
            const scx_state = @import("clients/scx_scheds.zig").getPreviousState();
            if (scx_state.scheduler) |s| {
                const mode_str = if (scx_state.mode) |m| @tagName(m) else "default";
                try writer.print("  SCX Scheduler: {s} (Mode: {s})\n", .{ s.toScxName(), mode_str });
            } else {
                try writer.writeAll("  SCX Scheduler: (None)\n");
            }

            // Power Profile Restore State
            if (power_profiles) |pp| {
                if (pp.original_profile) |orig| {
                    try writer.print("  Power Profile: {s}\n", .{orig});
                } else {
                    try writer.writeAll("  Power Profile: (No change/None)\n");
                }
            } else {
                try writer.writeAll("  Power Profile: (Unavailable)\n");
            }
            try writer.writeAll("\n");
        }

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

        if (profile_manager.inhibit_cookie != null) {
            try writer.writeAll("  Screensaver Inhibit: Active\n");
        } else {
            try writer.writeAll("  Screensaver Inhibit: Inactive\n");
        }

        try writer.writeAll("\n");

        // Write to permanent status file
        std.fs.makeDirAbsolute(status_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const file = try std.fs.createFileAbsolute(status_file, .{ .mode = 0o644 });
        defer file.close();
        file.chmod(0o644) catch {};

        var write_buffer: [4096]u8 = undefined;
        var file_buffered_writer = file.writer(&write_buffer);
        const file_writer = &file_buffered_writer.interface;

        try file_writer.writeAll(buffer.items);
        try file_writer.flush(); // Don't forget to flush!

        // Write to tmp status file
        const tmp_file = try std.fs.createFileAbsolute(tmp_status_file, .{ .mode = 0o644 });
        defer tmp_file.close();
        tmp_file.chmod(0o644) catch {};

        var tmp_buffered_writer = tmp_file.writer(&write_buffer);
        const tmp_writer = &tmp_buffered_writer.interface;

        try tmp_writer.writeAll(buffer.items);
        try tmp_writer.flush(); // Don't forget to flush!
    }
};
