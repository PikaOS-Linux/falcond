const std = @import("std");
const confloader = @import("../config/confloader.zig");
const types = @import("types.zig");
const Profile = types.Profile;

pub fn loadProfiles(allocator: std.mem.Allocator, profiles: *std.ArrayList(Profile), proton_profile: *?*const Profile, oneshot: bool) !void {
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
        var loaded_profiles = try confloader.loadConfDir(Profile, allocator, "/usr/share/falcond/profiles");
        defer loaded_profiles.deinit();

        try profiles.appendSlice(loaded_profiles.items);

        for (profiles.items) |*profile| {
            if (std.mem.eql(u8, profile.name, "Proton")) {
                proton_profile.* = profile;
                std.log.info("Found Proton profile: {s}", .{profile.name});
                break;
            }
        }

        std.log.info("Loaded {d} profiles", .{profiles.items.len});
    }
}
