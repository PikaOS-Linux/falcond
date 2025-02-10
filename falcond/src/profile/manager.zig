const std = @import("std");
const types = @import("types.zig");
const matcher = @import("matcher.zig");
const Profile = types.Profile;
const PowerProfiles = @import("../clients/power_profiles.zig").PowerProfiles;
const Config = @import("../config/config.zig").Config;
const vcache_setting = @import("../clients/vcache_setting.zig");
const scx_scheds = @import("../clients/scx_scheds.zig");

pub const ProfileManager = struct {
    comptime profiles_dir: []const u8 = "/usr/share/falcond/profiles",
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(Profile),
    proton_profile: ?*const Profile,
    active_profile: ?*const Profile = null,
    queued_profiles: std.ArrayList(*const Profile),
    power_profiles: ?*PowerProfiles,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, power_profiles: ?*PowerProfiles, config: Config) ProfileManager {
        return .{
            .allocator = allocator,
            .profiles = std.ArrayList(Profile).init(allocator),
            .proton_profile = null,
            .queued_profiles = std.ArrayList(*const Profile).init(allocator),
            .power_profiles = power_profiles,
            .config = config,
        };
    }

    pub fn deinit(self: *ProfileManager) void {
        if (self.active_profile) |profile| {
            self.deactivateProfile(profile) catch |err| {
                std.log.err("Failed to deactivate profile: {}", .{err});
            };
        }

        for (self.profiles.items) |profile| {
            self.allocator.free(profile.name);
        }
        self.profiles.deinit();
        self.queued_profiles.deinit();
    }

    pub fn activateProfile(self: *ProfileManager, profile: *const Profile) !void {
        if (self.active_profile == null) {
            std.log.info("Activating profile: {s}", .{profile.name});
            self.active_profile = profile;

            if (profile.performance_mode and self.power_profiles != null and self.power_profiles.?.isPerformanceAvailable()) {
                std.log.info("Enabling performance mode for profile: {s}", .{profile.name});
                self.power_profiles.?.enablePerformanceMode();
            }

            const effective_mode = if (self.config.vcache_mode != .none)
                self.config.vcache_mode
            else
                profile.vcache_mode;
            vcache_setting.applyVCacheMode(effective_mode);

            const effective_sched = if (self.config.scx_sched == .none)
                profile.scx_sched
            else
                self.config.scx_sched;

            const effective_scx_mode = if (self.config.scx_sched == .none)
                profile.scx_sched_props
            else
                self.config.scx_sched_props;

            scx_scheds.applyScheduler(self.allocator, effective_sched, effective_scx_mode);
        } else {
            std.log.info("Queueing profile: {s} (active: {s})", .{ profile.name, self.active_profile.?.name });
            try self.queued_profiles.append(profile);
        }
    }

    pub fn deactivateProfile(self: *ProfileManager, profile: *const Profile) !void {
        if (self.active_profile) |active| {
            if (active == profile) {
                std.log.info("Deactivating profile: {s}", .{profile.name});

                if (profile.performance_mode and self.power_profiles != null and self.power_profiles.?.isPerformanceAvailable()) {
                    std.log.info("Disabling performance mode for profile: {s}", .{profile.name});
                    self.power_profiles.?.disablePerformanceMode();
                }

                vcache_setting.applyVCacheMode(.none);
                scx_scheds.restorePreviousState(self.allocator);
                self.active_profile = null;

                if (self.queued_profiles.items.len > 0) {
                    const next_profile = self.queued_profiles.orderedRemove(0);
                    try self.activateProfile(next_profile);
                }
            }
        }
    }

    pub fn unloadProfile(self: *ProfileManager, profile: *const Profile) !void {
        if (self.active_profile) |active| {
            if (active == profile) {
                std.log.info("Unloading profile: {s}", .{profile.name});

                if (profile.performance_mode and self.power_profiles != null and self.power_profiles.?.isPerformanceAvailable()) {
                    std.log.info("Disabling performance mode for profile: {s}", .{profile.name});
                    self.power_profiles.?.disablePerformanceMode();
                }

                vcache_setting.applyVCacheMode(.none);
                scx_scheds.restorePreviousState(self.allocator);
                self.active_profile = null;
            }
        }
    }

    pub fn matchProcess(self: *ProfileManager, arena: std.mem.Allocator, pid: []const u8, process_name: []const u8) !?*const Profile {
        return matcher.matchProcess(self.profiles.items, self.proton_profile, arena, pid, process_name, self.config);
    }
};
