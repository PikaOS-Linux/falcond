const std = @import("std");
const fs = std.fs;
const confloader = @import("confloader.zig");
const PowerProfiles = @import("power_profiles.zig").PowerProfiles;
const Config = @import("config.zig").Config;
const vcache_setting = @import("vcache_setting.zig");
const scx_scheds = @import("scx_scheds.zig");
const Child = std.process.Child;
const linux = std.os.linux;
const CPU_SETSIZE = 1024;
const CPU_SET = extern struct {
    bits: [CPU_SETSIZE / 64]u64,
};

pub const Profile = struct {
    const LscpuCoreStrategy = enum { HighestFreq, Sequential };

    name: []const u8,
    performance_mode: bool = false,
    scx_sched: scx_scheds.ScxScheduler = .none,
    scx_sched_props: ?scx_scheds.ScxSchedModes = null,
    vcache_mode: vcache_setting.VCacheMode = .cache,

    pub fn matches(self: *const Profile, process_name: []const u8) bool {
        const is_match = std.ascii.eqlIgnoreCase(self.name, process_name);
        if (is_match) {
            std.log.info("Found match: {s} for process {s}", .{ self.name, process_name });
        }
        return is_match;
    }
};

const CacheEntry = struct {
    pid: u32,
    timestamp: i64,
    is_proton: bool,
};

pub const ProfileManager = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(Profile),
    proton_profile: ?*const Profile,
    active_profile: ?*const Profile = null,
    queued_profiles: std.ArrayList(*const Profile),
    power_profiles: *PowerProfiles,
    config: *const Config,

    // Don't match Wine/Proton infrastructure
    const system_processes = [_][]const u8{
        "steam.exe",
        "services.exe",
        "winedevice.exe",
        "plugplay.exe",
        "svchost.exe",
        "explorer.exe",
        "rpcss.exe",
        "tabtip.exe",
        "wineboot.exe",
        "rundll32.exe",
        "iexplore.exe",
        "conhost.exe",
        "crashpad_handler.exe",
        "iscriptevaluator.exe",
        "VC_redist.x86.exe",
        "VC_redist.x64.exe",
        "cmd.exe",
        "REDEngineErrorReporter.exe",
        "REDprelauncher.exe",
        "SteamService.exe",
        "UnityCrashHandler64.exe",
        "start.exe",
    };

    pub fn init(allocator: std.mem.Allocator, power_profiles: *PowerProfiles, config: *const Config) ProfileManager {
        return .{
            .allocator = allocator,
            .profiles = std.ArrayList(Profile).init(allocator),
            .proton_profile = null,
            .queued_profiles = std.ArrayList(*const Profile).init(allocator),
            .power_profiles = power_profiles,
            .config = config,
        };
    }

    pub fn activateProfile(self: *ProfileManager, profile: *const Profile) !void {
        if (self.active_profile == null) {
            std.log.info("Activating profile: {s}", .{profile.name});
            self.active_profile = profile;

            if (profile.performance_mode and self.power_profiles.isPerformanceAvailable()) {
                std.log.info("Enabling performance mode for profile: {s}", .{profile.name});
                self.power_profiles.enablePerformanceMode();
            }

            const effective_mode = if (self.config.vcache_mode != .none)
                self.config.vcache_mode
            else
                profile.vcache_mode;
            vcache_setting.applyVCacheMode(effective_mode);

            const effective_sched = if (self.config.scx_sched != .none)
                self.config.scx_sched
            else
                profile.scx_sched;

            const effective_scx_mode = if (self.config.scx_sched != .none)
                self.config.scx_sched_props
            else
                profile.scx_sched_props;

            scx_scheds.applyScheduler(self.allocator, effective_sched, effective_scx_mode);
        } else {
            std.log.info("Queueing profile: {s} (active: {s})", .{ profile.name, self.active_profile.?.name });
            try self.queued_profiles.append(profile);
        }
    }

    pub fn deactivateProfile(self: *ProfileManager, profile: *const Profile) !void {
        if (self.active_profile == profile) {
            std.log.info("Deactivating profile: {s}", .{profile.name});
            self.active_profile = null;

            if (profile.performance_mode) {
                std.log.info("Disabling performance mode for profile: {s}", .{profile.name});
                self.power_profiles.disablePerformanceMode();
            }

            vcache_setting.applyVCacheMode(.none);
            scx_scheds.restorePreviousState(self.allocator);
            if (self.queued_profiles.items.len > 0) {
                const next_profile = self.queued_profiles.orderedRemove(0);
                std.log.info("Activating next queued profile: {s}", .{next_profile.name});
                try self.activateProfile(next_profile);
            }
        } else {
            for (self.queued_profiles.items, 0..) |queued, i| {
                if (queued == profile) {
                    std.log.info("Removing queued profile: {s}", .{profile.name});
                    _ = self.queued_profiles.orderedRemove(i);
                    break;
                }
            }
        }
    }

    pub fn loadProfiles(self: *ProfileManager, oneshot: bool) !void {
        if (oneshot) {
            try self.profiles.append(Profile{
                .name = try self.allocator.dupe(u8, "Hades3.exe"),
            });
            std.log.info("Loaded oneshot profile: Hades3.exe", .{});

            try self.profiles.append(Profile{
                .name = try self.allocator.dupe(u8, "Proton"),
            });
            std.log.info("Loaded oneshot profile: Proton", .{});

            self.proton_profile = &self.profiles.items[1];
        } else {
            var profiles = try confloader.loadConfDir(Profile, self.allocator, "/usr/share/falcond/profiles");
            defer profiles.deinit();

            try self.profiles.appendSlice(profiles.items);

            for (self.profiles.items) |*profile| {
                if (std.mem.eql(u8, profile.name, "Proton")) {
                    self.proton_profile = profile;
                    std.log.info("Found Proton profile: {s}", .{profile.name});
                    break;
                }
            }

            std.log.info("Loaded {d} profiles", .{self.profiles.items.len});
        }
    }

    fn isProtonParent(_: *const ProfileManager, arena: std.mem.Allocator, pid: []const u8) !bool {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const status_path = try std.fmt.bufPrint(&path_buf, "/proc/{s}/status", .{pid});

        const file = std.fs.openFileAbsolute(status_path, .{}) catch |err| {
            std.log.debug("Failed to open {s}: {}", .{ status_path, err });
            return switch (err) {
                error.AccessDenied, error.FileNotFound => false,
                else => err,
            };
        };
        defer file.close();

        const content = try file.readToEndAlloc(arena, std.math.maxInt(usize));

        const ppid_line = std.mem.indexOf(u8, content, "PPid:") orelse return false;
        const line_end = std.mem.indexOfScalarPos(u8, content, ppid_line, '\n') orelse content.len;
        const ppid_start = ppid_line + 5; // Length of "PPid:"
        const ppid = std.mem.trim(u8, content[ppid_start..line_end], " \t");

        const parent_cmdline_path = try std.fmt.bufPrint(&path_buf, "/proc/{s}/cmdline", .{ppid});
        const parent_file = std.fs.openFileAbsolute(parent_cmdline_path, .{}) catch |err| {
            std.log.debug("Failed to open parent cmdline {s}: {}", .{ parent_cmdline_path, err });
            return switch (err) {
                error.AccessDenied, error.FileNotFound => false,
                else => err,
            };
        };
        defer parent_file.close();

        const parent_content = try parent_file.readToEndAlloc(arena, std.math.maxInt(usize));
        return std.mem.indexOf(u8, parent_content, "proton") != null;
    }

    fn isProtonGame(self: *ProfileManager, arena: std.mem.Allocator, pid: []const u8, process_name: []const u8) !bool {
        if (!std.mem.endsWith(u8, process_name, ".exe")) return false;

        for (system_processes) |sys_proc| {
            if (std.mem.eql(u8, process_name, sys_proc)) {
                return false;
            }
        }

        return try self.isProtonParent(arena, pid);
    }

    pub fn matchProcess(self: *ProfileManager, arena: std.mem.Allocator, pid: []const u8, process_name: []const u8) !?*const Profile {
        const is_exe = std.mem.endsWith(u8, process_name, ".exe");
        var match: ?*const Profile = null;

        for (self.profiles.items) |*profile| {
            const is_match = profile != self.proton_profile and profile.matches(process_name);
            if (is_match) {
                std.log.info("Matched profile {s} for process {s}", .{ profile.name, process_name });
                match = profile;
                break;
            }
        }

        const should_check_proton = match == null and
            is_exe and
            self.proton_profile != null;

        if (should_check_proton) {
            const is_system = for (system_processes) |sys_proc| {
                if (std.mem.eql(u8, process_name, sys_proc)) break true;
            } else false;

            if (!is_system) {
                const is_proton = try self.isProtonParent(arena, pid);
                if (is_proton) {
                    std.log.info("Found Proton game: {s}", .{process_name});
                    match = self.proton_profile;
                }
            }
        }

        return match;
    }

    pub fn deinit(self: *ProfileManager) void {
        if (self.active_profile) |profile| {
            if (profile.performance_mode) {
                self.power_profiles.disablePerformanceMode();
            }
        }

        for (self.profiles.items) |*profile| {
            self.allocator.free(profile.name);
        }
        self.queued_profiles.deinit();
        self.profiles.deinit();
    }
};
