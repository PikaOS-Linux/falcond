const std = @import("std");
const confloader = @import("../config/confloader.zig");
const types = @import("types.zig");
const Profile = types.Profile;
const ProfileMode = @import("../config/config.zig").ProfileMode;

pub fn loadProfiles(allocator: std.mem.Allocator, profiles: *std.ArrayListUnmanaged(Profile), proton_profile: *?*const Profile, oneshot: bool, mode: ProfileMode) !void {
    if (oneshot) {
        try profiles.append(allocator, Profile{
            .name = try allocator.dupe(u8, "Hades3.exe"),
            .scx_sched = .bpfland,
        });
        std.log.info("Loaded oneshot profile: Hades3.exe", .{});

        try profiles.append(allocator, Profile{
            .name = try allocator.dupe(u8, "Proton"),
            .scx_sched = .none,
        });
        std.log.info("Loaded oneshot profile: Proton", .{});

        proton_profile.* = &profiles.items[1];
    } else {
        const base_path = "/usr/share/falcond/profiles";
        const user_profiles_path = "/usr/share/falcond/profiles/user";
        const profiles_path = if (mode != .none)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, @tagName(mode) })
        else
            base_path;
        defer if (mode != .none) allocator.free(profiles_path);

        var loaded_profiles = try confloader.loadConfDir(Profile, allocator, profiles_path);
        defer loaded_profiles.deinit(allocator);

        try profiles.appendSlice(allocator, loaded_profiles.items);

        const has_user_profiles = blk: {
            _ = std.fs.accessAbsolute(user_profiles_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.debug("User profiles directory not found: {s}", .{user_profiles_path});
                } else {
                    std.log.err("Failed to access user profiles directory: {s} - {s}", .{ user_profiles_path, @errorName(err) });
                }
                break :blk false;
            };
            break :blk true;
        };

        var user_count: usize = 0;
        if (has_user_profiles) {
            var user_loaded_profiles = try confloader.loadConfDir(Profile, allocator, user_profiles_path);
            defer user_loaded_profiles.deinit(allocator);
            user_count = user_loaded_profiles.items.len;
            for (user_loaded_profiles.items) |user_profile| {
                var found = false;
                for (profiles.items) |*profile| {
                    if (std.mem.eql(u8, profile.name, user_profile.name)) {
                        profile.* = user_profile;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try profiles.append(allocator, user_profile);
                }
            }
        }

        for (profiles.items) |*profile| {
            if (std.mem.eql(u8, profile.name, "Proton")) {
                proton_profile.* = profile;
                break;
            }
        }

        std.log.info("Loaded {d} profiles ({d} user profiles) (mode: {s})", .{ profiles.items.len, user_count, @tagName(mode) });
    }
}
