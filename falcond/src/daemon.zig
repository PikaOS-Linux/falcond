const std = @import("std");
const ProfileManager = @import("profile.zig").ProfileManager;
const Profile = @import("profile.zig").Profile;
const Config = @import("config.zig").Config;
const linux = std.os.linux;
const posix = std.posix;
const PowerProfiles = @import("power_profiles.zig").PowerProfiles;
const scx_scheds = @import("scx_scheds.zig");

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    profile_manager: ProfileManager,
    oneshot: bool,
    known_pids: ?std.AutoHashMap(u32, *const Profile),
    power_profiles: *PowerProfiles,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ?*Config, oneshot: bool, power_profiles: *PowerProfiles) !Self {
        var profile_manager = ProfileManager.init(allocator, power_profiles, config.?);
        try profile_manager.loadProfiles(oneshot);

        try scx_scheds.init(allocator);

        return Self{
            .allocator = allocator,
            .profile_manager = profile_manager,
            .oneshot = oneshot,
            .known_pids = null,
            .power_profiles = power_profiles,
        };
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

    pub fn checkProcesses(self: *Self) !void {
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
                        if (try self.profile_manager.matchProcess(arena.allocator(), try std.fmt.allocPrint(arena_allocator, "{d}", .{pid}), process_name)) |profile| {
                            try known.put(pid, profile);
                            try self.profile_manager.activateProfile(profile);
                        }
                    }
                }
            } else {
                try self.handleProcess(try std.fmt.allocPrint(arena_allocator, "{d}", .{pid}), process_name);
            }
        }

        if (!self.oneshot) {
            if (self.known_pids) |*known| {
                var known_it = known.iterator();
                while (known_it.next()) |entry| {
                    const pid = entry.key_ptr.*;
                    if (!processes.contains(pid)) {
                        try self.handleProcessExit(try std.fmt.allocPrint(arena_allocator, "{d}", .{pid}));
                    }
                }
            }
        }
    }

    pub fn run(self: *Self) !void {
        if (!self.oneshot) {
            self.known_pids = std.AutoHashMap(u32, *const Profile).init(self.allocator);
        }

        try self.checkProcesses();

        if (self.oneshot) {
            return;
        }

        while (true) {
            try self.checkProcesses();
            std.time.sleep(std.time.ns_per_s * 3);
        }
    }

    pub fn deinit(self: *Self) void {
        scx_scheds.deinit();
        if (self.known_pids) |*pids| {
            pids.deinit();
        }
        self.profile_manager.deinit();
    }

    pub fn handleProcess(self: *Self, pid: []const u8, process_name: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        if (try self.profile_manager.matchProcess(arena.allocator(), pid, process_name)) |profile| {
            if (!self.oneshot) {
                if (self.known_pids) |*known| {
                    try known.put(try std.fmt.parseInt(u32, pid, 10), profile);
                }
            }
            try self.profile_manager.activateProfile(profile);
        }
    }

    pub fn handleProcessExit(self: *Self, pid: []const u8) !void {
        if (self.known_pids) |*pids| {
            const pid_num = std.fmt.parseInt(u32, pid, 10) catch |err| {
                std.log.warn("Failed to parse PID: {}", .{err});
                return;
            };

            if (pids.get(pid_num)) |profile| {
                var found_profile = false;

                if (self.profile_manager.active_profile) |active| {
                    if (active == profile) {
                        std.log.info("Process {s} has terminated", .{profile.name});
                        try self.profile_manager.deactivateProfile(active);
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

                _ = pids.remove(pid_num);
            }
        }
    }
};
