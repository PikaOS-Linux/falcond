const std = @import("std");
const os = std.os;
const types = @import("types.zig");
const matcher = @import("matcher.zig");
const Profile = types.Profile;
const PowerProfiles = @import("../clients/power_profiles.zig").PowerProfiles;
const Config = @import("../config/config.zig").Config;
const vcache_setting = @import("../clients/vcache_setting.zig");
const scx_scheds = @import("../clients/scx_scheds.zig");
const scriptrunner = @import("../clients/scriptrunner.zig");
const Screensaver = @import("../clients/screensaver.zig").Screensaver;

pub const ProfileProcessInfo = struct {
    pids: std.ArrayListUnmanaged([]const u8),
    uid: ?os.linux.uid_t,

    pub fn init() ProfileProcessInfo {
        return .{
            .pids = std.ArrayListUnmanaged([]const u8){},
            .uid = null,
        };
    }

    pub fn deinit(self: *ProfileProcessInfo, allocator: std.mem.Allocator) void {
        for (self.pids.items) |pid| {
            allocator.free(pid);
        }
        self.pids.deinit(allocator);
    }

    pub fn removePid(self: *ProfileProcessInfo, allocator: std.mem.Allocator, pid_to_remove: []const u8) bool {
        for (self.pids.items, 0..) |pid, i| {
            if (std.mem.eql(u8, pid, pid_to_remove)) {
                allocator.free(self.pids.orderedRemove(i));
                return true;
            }
        }
        return false;
    }
};

pub const ProfileManager = struct {
    comptime profiles_dir: []const u8 = "/usr/share/falcond/profiles",
    allocator: std.mem.Allocator,
    profiles: std.ArrayListUnmanaged(Profile),
    proton_profile: ?*const Profile,
    active_profile: ?*const Profile = null,
    queued_profiles: std.ArrayListUnmanaged(*const Profile),
    power_profiles: ?*PowerProfiles,
    config: Config,
    profile_process_info: std.AutoHashMap(*const Profile, ProfileProcessInfo),
    file_count: usize = 0,
    screensaver: ?*Screensaver = null,
    inhibit_cookie: ?Screensaver.Cookie = null,
    inhibit_uid: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, power_profiles: ?*PowerProfiles, config: Config) ProfileManager {
        var screensaver: ?*Screensaver = null;
        if (Screensaver.init(allocator)) |ss| {
            screensaver = ss;
        } else |err| {
            std.log.warn("Failed to initialize Screensaver client: {}, idle inhibition will be disabled", .{err});
        }

        return .{
            .allocator = allocator,
            .profiles = std.ArrayListUnmanaged(Profile){},
            .proton_profile = null,
            .queued_profiles = std.ArrayListUnmanaged(*const Profile){},
            .power_profiles = power_profiles,
            .config = config,
            .profile_process_info = std.AutoHashMap(*const Profile, ProfileProcessInfo).init(allocator),
            .screensaver = screensaver,
        };
    }

    pub fn updateFileCount(self: *ProfileManager, maybe_count: ?usize) !void {
        if (maybe_count) |count| {
            self.file_count = count;
            return;
        }

        const user_profiles_path = "/usr/share/falcond/profiles/user";
        var count: usize = 0;
        var dir = try std.fs.cwd().openDir(self.profiles_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf")) {
                count += 1;
            }
        }

        var user_dir = std.fs.cwd().openDir(user_profiles_path, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) {
                std.log.err("Failed to open user profiles directory: {s} - {s}", .{ user_profiles_path, @errorName(err) });
            } else {
                std.log.debug("User profiles directory not found: {s}", .{user_profiles_path});
            }
            self.file_count = count;
            return;
        };
        defer user_dir.close();

        var user_iter = user_dir.iterate();
        while (try user_iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf")) {
                count += 1;
            }
        }

        self.file_count = count;
    }

    pub fn deinit(self: *ProfileManager, allocator: std.mem.Allocator) void {
        if (self.active_profile) |profile| {
            self.deactivateProfile(profile, null) catch |err| {
                std.log.err("Failed to deactivate profile: {}", .{err});
            };
        }

        // Free all process IDs stored in the map
        var it = self.profile_process_info.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.profile_process_info.deinit();

        if (self.screensaver) |ss| {
            ss.deinit();
        }

        for (self.profiles.items) |profile| {
            self.allocator.free(profile.name);
        }
        self.profiles.deinit(allocator);
        self.queued_profiles.deinit(allocator);
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

            if (profile.idle_inhibit and self.screensaver != null) {
                const info = self.profile_process_info.get(profile);
                const uid = if (info) |i| i.uid else null;

                if (self.screensaver.?.inhibit("falcond", "Gaming Profile Active", uid)) |cookie| {
                    self.inhibit_cookie = cookie;
                    self.inhibit_uid = uid;
                    std.log.info("Inhibited screensaver (cookie: {})", .{cookie});
                } else |err| {
                    std.log.err("Failed to inhibit screensaver: {}", .{err});
                }
            }

            const effective_sched = if (self.config.scx_sched == .none)
                profile.scx_sched
            else
                self.config.scx_sched;

            const effective_scx_mode = if (self.config.scx_sched == .none)
                profile.scx_sched_props
            else
                self.config.scx_sched_props;

            if (profile.start_script != null) {
                // Get the process info for this profile from the map
                if (self.profile_process_info.get(profile)) |process_info| {
                    if (process_info.pids.items.len > 0) {
                        // Use the first PID for the script
                        scriptrunner.runScript(self.allocator, profile.start_script.?, process_info.pids.items[0], process_info.uid);
                    } else {
                        std.log.warn("Cannot run start script for profile {s}: no PIDs available", .{profile.name});
                    }
                } else {
                    std.log.warn("Cannot run start script for profile {s}: no process info available", .{profile.name});
                }
            }

            scx_scheds.applyScheduler(self.allocator, effective_sched, effective_scx_mode);
        } else {
            // Don't queue the profile if it's already active
            if (self.active_profile.? == profile) {
                std.log.debug("Profile {s} is already active, not queueing", .{profile.name});
                return;
            }
            std.log.info("Queueing profile: {s} (active: {s})", .{ profile.name, self.active_profile.?.name });
            try self.queued_profiles.append(self.allocator, profile);
        }
    }

    pub fn deactivateProfile(self: *ProfileManager, profile: *const Profile, pid: ?[]const u8) !void {
        if (self.active_profile) |active| {
            if (active == profile) {
                // Check if there are multiple instances of this profile
                if (self.profile_process_info.getPtr(profile)) |process_info| {
                    if (pid != null) {
                        // Remove the specific PID
                        const removed = process_info.removePid(self.allocator, pid.?);
                        if (removed) {
                            std.log.debug("Removed PID {s} from profile {s}, {d} instances remaining", .{ pid.?, profile.name, process_info.pids.items.len });
                            if (process_info.pids.items.len > 0) {
                                return;
                            }
                        } else {
                            std.log.warn("Failed to find PID {s} in profile {s}", .{ pid.?, profile.name });
                            if (process_info.pids.items.len > 0) {
                                return;
                            }
                        }
                    }
                }

                std.log.info("Deactivating profile: {s}", .{profile.name});

                if (profile.performance_mode and self.power_profiles != null and self.power_profiles.?.isPerformanceAvailable()) {
                    std.log.info("Disabling performance mode for profile: {s}", .{profile.name});
                    self.power_profiles.?.disablePerformanceMode();
                }

                if (self.inhibit_cookie) |cookie| {
                    if (self.screensaver) |ss| {
                        ss.uninhibit(cookie, self.inhibit_uid) catch |err| {
                            std.log.err("Failed to uninhibit screensaver: {}", .{err});
                        };
                        std.log.info("Uninhibited screensaver", .{});
                    }
                    self.inhibit_cookie = null;
                    self.inhibit_uid = null;
                }

                vcache_setting.applyVCacheMode(.none);
                scx_scheds.restorePreviousState(self.allocator);
                self.active_profile = null;

                if (profile.stop_script != null) {
                    // Get the process info for this profile from the map
                    if (self.profile_process_info.get(profile)) |process_info| {
                        // Determine which PID to use for the script
                        if (pid != null) {
                            // Use the specific PID that's being deactivated
                            scriptrunner.runScript(self.allocator, profile.stop_script.?, pid.?, process_info.uid);
                        } else if (process_info.pids.items.len > 0) {
                            // Use the first PID in the list
                            scriptrunner.runScript(self.allocator, profile.stop_script.?, process_info.pids.items[0], process_info.uid);
                        } else {
                            std.log.warn("Cannot run stop script for profile {s}: no PIDs available", .{profile.name});
                        }
                    } else {
                        std.log.warn("Cannot run stop script for profile {s}: no process info available", .{profile.name});
                    }
                }

                // Remove the entire entry
                if (self.profile_process_info.fetchRemove(profile)) |kv| {
                    // Create a mutable copy to call deinit
                    var mutable_info = kv.value;
                    mutable_info.deinit(self.allocator);
                    std.log.debug("Removed last instance of profile {s}", .{profile.name});
                }

                if (self.queued_profiles.items.len > 0) {
                    const next_profile = self.queued_profiles.items[0];

                    // If the next profile is the same as the one we just deactivated, remove it from the queue
                    if (next_profile == profile) {
                        _ = self.queued_profiles.orderedRemove(0);
                        std.log.info("Removed duplicate profile from queue: {s}", .{profile.name});
                    }

                    // Only activate the next profile if there's still something in the queue
                    if (self.queued_profiles.items.len > 0) {
                        const profile_to_activate = self.queued_profiles.orderedRemove(0);
                        try self.activateProfile(profile_to_activate);
                    }
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

                if (self.inhibit_cookie) |cookie| {
                    if (self.screensaver) |ss| {
                        ss.uninhibit(cookie, self.inhibit_uid) catch |err| {
                            std.log.err("Failed to uninhibit screensaver: {}", .{err});
                        };
                        std.log.info("Uninhibited screensaver", .{});
                    }
                    self.inhibit_cookie = null;
                    self.inhibit_uid = null;
                }

                vcache_setting.applyVCacheMode(.none);
                scx_scheds.restorePreviousState(self.allocator);
                self.active_profile = null;
            }
        }
    }

    pub fn matchProcess(self: *ProfileManager, arena: std.mem.Allocator, pid: []const u8, process_name: []const u8) !?*const Profile {
        const match = try matcher.matchProcess(self.profiles.items, self.proton_profile, arena, pid, process_name, self.config);

        // Store the process ID and user ID if we have a match
        if (match != null) {
            // Make a copy of the pid since it might be from a temporary arena
            const pid_copy = try self.allocator.dupe(u8, pid);

            // Try to find the user ID for this process
            const uid = scriptrunner.findUserForProcess(pid) catch null;

            // Check if we already have an entry for this profile
            if (self.profile_process_info.getPtr(match.?)) |process_info| {
                // Add the new PID to the existing entry
                try process_info.pids.append(self.allocator, pid_copy);

                // Update UID if it was null before
                if (process_info.uid == null) {
                    process_info.uid = uid;
                }

                std.log.info("Added another instance of profile {s}, now {d} instances", .{ match.?.name, process_info.pids.items.len });
            } else {
                // Create a new entry for this profile
                var process_info = ProfileProcessInfo.init();
                try process_info.pids.append(self.allocator, pid_copy);
                process_info.uid = uid;

                self.profile_process_info.put(match.?, process_info) catch |err| {
                    std.log.err("Failed to store process info for profile {s}: {}", .{ match.?.name, err });
                    // Free the pid_copy and the process_info if we couldn't store it
                    process_info.deinit(self.allocator);
                };

                std.log.info("Created new profile instance for {s}", .{match.?.name});
            }
        }

        // Check if we have a match for an .exe file (not Proton) and Proton is currently active
        if (match != null and
            std.mem.endsWith(u8, process_name, ".exe") and
            match != self.proton_profile and
            self.active_profile == self.proton_profile)
        {
            std.log.info("Overriding Proton profile with .exe profile: {s}", .{match.?.name});

            // Deactivate the Proton profile but don't run its stop script yet
            if (self.active_profile) |active| {
                // Save the current Proton profile to add to queue later
                const proton = active;

                // Deactivate without running stop script
                if (proton.performance_mode and self.power_profiles != null and self.power_profiles.?.isPerformanceAvailable()) {
                    std.log.info("Disabling performance mode for Proton profile", .{});
                    self.power_profiles.?.disablePerformanceMode();
                }

                if (self.inhibit_cookie) |cookie| {
                    if (self.screensaver) |ss| {
                        ss.uninhibit(cookie, self.inhibit_uid) catch |err| {
                            std.log.err("Failed to uninhibit screensaver: {}", .{err});
                        };
                        std.log.info("Uninhibited screensaver", .{});
                    }
                    self.inhibit_cookie = null;
                    self.inhibit_uid = null;
                }

                vcache_setting.applyVCacheMode(.none);
                scx_scheds.restorePreviousState(self.allocator);
                self.active_profile = null;

                // Add Proton to the front of the queue
                try self.queued_profiles.insert(self.allocator, 0, proton);
                std.log.info("Added Proton profile to front of queue", .{});
            }

            // Activate the .exe profile
            try self.activateProfile(match.?);
        }

        return match;
    }
};
