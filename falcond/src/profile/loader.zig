const std = @import("std");
const confloader = @import("../config/confloader.zig");
const types = @import("types.zig");
const Profile = types.Profile;
const ProfileMode = @import("../config/config.zig").ProfileMode;

pub fn loadProfiles(allocator: std.mem.Allocator, profiles: *std.ArrayList(Profile), proton_profile: *?*const Profile, oneshot: bool, mode: ProfileMode) !void {
    if (oneshot) {
        try profiles.append(Profile{
            .name = try allocator.dupe(u8, "Hades3.exe"),
            .scx_sched = .bpfland,
        });
        std.log.info("Loaded oneshot profile: Hades3.exe", .{});

        try profiles.append(Profile{
            .name = try allocator.dupe(u8, "Proton"),
            .scx_sched = .none,
        });
        std.log.info("Loaded oneshot profile: Proton", .{});

        proton_profile.* = &profiles.items[1];
    } else {
        const base_path = "/usr/share/falcond/profiles";
        const profiles_path = if (mode != .none)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, @tagName(mode) })
        else
            base_path;
        defer if (mode != .none) allocator.free(profiles_path);

        var loaded_profiles = try confloader.loadConfDir(Profile, allocator, profiles_path);
        defer loaded_profiles.deinit();

        try profiles.appendSlice(loaded_profiles.items);

        for (profiles.items) |*profile| {
            if (std.mem.eql(u8, profile.name, "Proton")) {
                proton_profile.* = profile;
                break;
            }
        }

        std.log.info("Loaded {d} profiles (mode: {s})", .{ profiles.items.len, @tagName(mode) });
    }
}
