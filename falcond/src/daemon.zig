const std = @import("std");
const ProfileManager = @import("profile/manager.zig").ProfileManager;
const Profile = @import("profile/types.zig").Profile;
const ProfileLoader = @import("profile/loader.zig");
const Config = @import("config/config.zig").Config;
const linux = std.os.linux;
const posix = std.posix;
const PowerProfiles = @import("clients/power_profiles.zig").PowerProfiles;
const scx_scheds = @import("clients/scx_scheds.zig");

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    config_path: []const u8,
    system_conf_path: []const u8,
    profile_manager: ProfileManager,
    oneshot: bool,
    known_pids: ?std.AutoHashMap(u32, *const Profile),
    power_profiles: ?*PowerProfiles,
    performance_mode: bool,
    last_profiles_check: i128,
    last_config_check: i128,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8, system_conf_path: []const u8, oneshot: bool) !*Self {
        const config_path_owned = try allocator.dupe(u8, config_path);
        errdefer allocator.free(config_path_owned);

        const system_conf_path_owned = try allocator.dupe(u8, system_conf_path);
        errdefer allocator.free(system_conf_path_owned);

        var config = try Config.load(allocator, config_path, system_conf_path);
        errdefer config.deinit();

        const power_profiles = try PowerProfiles.init(allocator, config);
        var performance_mode = false;

        if (power_profiles) |pp| {
            performance_mode = pp.isPerformanceAvailable();
            if (performance_mode) {
                std.log.info("Performance profile available - power profile management enabled", .{});
            }
        }

        var profile_manager = ProfileManager.init(allocator, power_profiles, config);
        try ProfileLoader.loadProfiles(allocator, &profile_manager.profiles, &profile_manager.proton_profile, oneshot, config.profile_mode);

        const current_time = std.time.nanoTimestamp();
        try scx_scheds.init(allocator);

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config_path = config_path_owned,
            .system_conf_path = system_conf_path_owned,
            .profile_manager = profile_manager,
            .oneshot = oneshot,
            .known_pids = if (!oneshot) std.AutoHashMap(u32, *const Profile).init(allocator) else null,
            .power_profiles = power_profiles,
            .last_profiles_check = current_time,
            .last_config_check = current_time,
            .performance_mode = performance_mode,
            .config = config,
        };

        try self.profile_manager.updateFileCount(null);

        return self;
    }

    pub fn deinit(self: *Self) void {
        scx_scheds.deinit();
        self.profile_manager.deinit();
        if (self.power_profiles) |pp| {
            pp.*.deinit();
        }
        if (self.known_pids) |*map| {
            map.deinit();
        }
        self.config.deinit();
        self.allocator.free(self.config_path);
        self.allocator.free(self.system_conf_path);
        self.allocator.destroy(self);
    }

    fn reloadConfig(self: *Self) !void {
        if (self.known_pids) |*map| {
            map.clearRetainingCapacity();
        }

        if (self.profile_manager.active_profile != null) {
            try self.profile_manager.unloadProfile(self.profile_manager.active_profile.?);
        }

        self.profile_manager.deinit();
        if (self.power_profiles) |pp| {
            pp.*.deinit();
        }
        self.config.deinit();

        const config = try Config.load(self.allocator, self.config_path, self.system_conf_path);
        const power_profiles = try PowerProfiles.init(self.allocator, config);
        var profile_manager = ProfileManager.init(self.allocator, power_profiles, config);
        try ProfileLoader.loadProfiles(self.allocator, &profile_manager.profiles, &profile_manager.proton_profile, self.oneshot, config.profile_mode);

        self.config = config;
        self.power_profiles = power_profiles;
        self.performance_mode = if (power_profiles) |pp| pp.isPerformanceAvailable() else false;
        self.profile_manager = profile_manager;

        try self.profile_manager.updateFileCount(null);
    }

    fn checkConfigChanges(self: *Self) !bool {
        const stat = try std.fs.cwd().statFile(self.config_path);
        const mtime = @as(i128, @intCast(stat.mtime));
        if (mtime > self.last_config_check) {
            std.log.info("Config file changed, reloading profiles", .{});
            self.last_config_check = std.time.nanoTimestamp();
            return true;
        }
        return false;
    }

    fn checkProfilesChanges(self: *Self) !bool {
        const user_profiles_path = "/usr/share/falcond/profiles/user";
        var dir = try std.fs.cwd().openDir(self.profile_manager.profiles_dir, .{ .iterate = true });
        defer dir.close();

        var latest_mtime: i128 = self.last_profiles_check;
        var current_file_count: usize = 0;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf")) {
                current_file_count += 1;

                const stat = try dir.statFile(entry.name);
                const mtime = @as(i128, @intCast(stat.mtime));
                if (mtime > latest_mtime) {
                    latest_mtime = mtime;
                }
            }
        }

        var user_dir = std.fs.cwd().openDir(user_profiles_path, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) {
                std.log.err("Failed to open user profiles directory: {s} - {s}", .{ user_profiles_path, @errorName(err) });
            }

            if (latest_mtime > self.last_profiles_check or current_file_count != self.profile_manager.file_count) {
                std.log.info("Profile changes detected in system profiles, reloading profiles", .{});
                self.last_profiles_check = std.time.nanoTimestamp();
                try self.profile_manager.updateFileCount(current_file_count);
                return true;
            }
            return false;
        };
        defer user_dir.close();

        var user_iter = user_dir.iterate();
        while (try user_iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf")) {
                current_file_count += 1;
                const stat = try user_dir.statFile(entry.name);
                const mtime = @as(i128, @intCast(stat.mtime));
                if (mtime > latest_mtime) {
                    latest_mtime = mtime;
                }
            }
        }

        if (latest_mtime > self.last_profiles_check or current_file_count != self.profile_manager.file_count) {
            std.log.info("Profile changes detected, reloading profiles", .{});
            self.last_profiles_check = std.time.nanoTimestamp();
            try self.profile_manager.updateFileCount(current_file_count);
            return true;
        }

        return false;
    }

    pub fn run(self: *Self) !void {
        if (self.oneshot) {
            try self.handleProcesses();
            return;
        }

        while (true) {
            const config_changed = try self.checkConfigChanges();
            const profiles_changed = try self.checkProfilesChanges();

            if (config_changed or profiles_changed) {
                try self.reloadConfig();
            }

            try self.handleProcesses();

            std.Thread.sleep(std.time.ns_per_s * 9);
        }
    }

    fn scanProcesses(allocator: std.mem.Allocator) !std.AutoHashMap(u32, []const u8) {
        var pids = std.AutoHashMap(u32, []const u8).init(allocator);

        const proc_fd = try std.posix.open("/proc", .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
        }, 0);
        defer std.posix.close(proc_fd);

        var buffer: [8192]u8 = undefined;
        while (true) {
            const nread = linux.syscall3(.getdents64, @as(usize, @intCast(proc_fd)), @intFromPtr(&buffer), buffer.len);

            if (nread == 0) break;
            if (nread < 0) return error.ReadDirError;

            var pos: usize = 0;
            while (pos < nread) {
                const dirent = @as(*align(1) linux.dirent64, @ptrCast(&buffer[pos]));
                if (dirent.type == linux.DT.DIR) {
                    const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&dirent.name)), 0);
                    if (std.fmt.parseInt(u32, name, 10)) |pid| {
                        if (getProcessNameFromPid(allocator, pid)) |proc_name| {
                            try pids.put(pid, proc_name);
                        } else |_| {}
                    } else |_| {}
                }
                pos += dirent.reclen;
            }
        }

        return pids;
    }

    fn getProcessNameFromPid(allocator: std.mem.Allocator, pid: u32) ![]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid});

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var buffer: [4096]u8 = undefined;
        const bytes = try file.readAll(&buffer);
        if (bytes == 0) return error.EmptyFile;

        const end = std.mem.indexOfScalar(u8, buffer[0..bytes], 0) orelse bytes;
        const cmdline = buffer[0..end];

        const last_unix = std.mem.lastIndexOfScalar(u8, cmdline, '/') orelse 0;
        const last_windows = std.mem.lastIndexOfScalar(u8, cmdline, '\\') orelse 0;
        const last_sep = @max(last_unix, last_windows);

        const exe_name = if (last_sep > 0)
            cmdline[last_sep + 1 ..]
        else
            cmdline;

        return try allocator.dupe(u8, exe_name);
    }

    fn handleProcesses(self: *Self) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var processes = try scanProcesses(arena_allocator);
        defer {
            var it = processes.iterator();
            while (it.next()) |entry| {
                arena_allocator.free(entry.value_ptr.*);
            }
            processes.deinit();
        }

        var it = processes.iterator();
        while (it.next()) |entry| {
            const pid = entry.key_ptr.*;
            const process_name = entry.value_ptr.*;

            if (!self.oneshot) {
                if (self.known_pids) |*known| {
                    if (!known.contains(pid)) {
                        if (try self.profile_manager.matchProcess(arena_allocator, try std.fmt.allocPrint(arena_allocator, "{d}", .{pid}), process_name)) |profile| {
                            try known.put(pid, profile);
                            try self.profile_manager.activateProfile(profile);
                        }
                    }
                }
            } else {
                if (try self.profile_manager.matchProcess(arena_allocator, try std.fmt.allocPrint(arena_allocator, "{d}", .{pid}), process_name)) |profile| {
                    try self.profile_manager.activateProfile(profile);
                }
            }
        }

        if (!self.oneshot) {
            if (self.known_pids) |*known| {
                var known_it = known.iterator();
                while (known_it.next()) |entry| {
                    const pid = entry.key_ptr.*;
                    if (!processes.contains(pid)) {
                        const profile = entry.value_ptr.*;
                        var found_profile = false;

                        if (self.profile_manager.active_profile) |active| {
                            if (active == profile) {
                                std.log.info("Process {s} instance has terminated", .{profile.name});
                                const pid_str = try std.fmt.allocPrint(arena_allocator, "{d}", .{pid});
                                try self.profile_manager.deactivateProfile(active, pid_str);
                                found_profile = true;
                            }
                        }

                        if (!found_profile) {
                            for (self.profile_manager.queued_profiles.items, 0..) |queued, i| {
                                if (queued == profile) {
                                    std.log.info("Process {s} has terminated", .{profile.name});
                                    _ = self.profile_manager.queued_profiles.orderedRemove(i);
                                    break;
                                }
                            }
                        }

                        _ = known.remove(pid);
                    }
                }
            }
        }
    }
};
