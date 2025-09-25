const std = @import("std");
const fs = std.fs;
const confloader = @import("confloader.zig");
const vcache_setting = @import("../clients/vcache_setting.zig");
const scx_scheds = @import("../clients/scx_scheds.zig");

pub const ProfileMode = enum {
    none,
    handheld,
    htpc,
};

pub const SystemConfig = struct {
    system_processes: []const []const u8 = &[_][]const u8{},
};

pub const Config = struct {
    enable_performance_mode: bool = true,
    scx_sched: scx_scheds.ScxScheduler = .none,
    scx_sched_props: ?scx_scheds.ScxSchedModes = null,
    vcache_mode: vcache_setting.VCacheMode = .none,
    system_processes: []const []const u8 = &[_][]const u8{},
    profile_mode: ProfileMode = .none,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn load(allocator: std.mem.Allocator, path: []const u8, system_conf_path: ?[]const u8) !Config {
        var config = Config{};
        const file = fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try config.save(path);
                return config;
            },
            else => return err,
        };
        defer file.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        config = try confloader.loadConf(Config, arena.allocator(), path);
        if (system_conf_path) |sys_path| {
            const system_file = fs.openFileAbsolute(sys_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (system_file) |sf| {
                defer sf.close();
                const system_config = try confloader.loadConf(SystemConfig, arena.allocator(), sys_path);
                config.system_processes = system_config.system_processes;
            }
        }

        config.arena = arena;
        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self.arena) |*arena| {
            arena.deinit();
            self.arena = null;
        }
    }

    pub fn save(self: Config, path: []const u8) !void {
        var file_buf: [fs.max_path_bytes]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(
            &file_buf,
            "{s}/",
            .{std.fs.path.dirname(path).?},
        );

        fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file = try fs.createFileAbsolute(path, .{});
        defer file.close();

        var writer_buffer: [256]u8 = undefined;
        var file_writer = file.writer(&writer_buffer);
        const writer = &file_writer.interface;

        try writer.print("enable_performance_mode = {}\n", .{self.enable_performance_mode});
        try writer.print("scx_sched = {s}\n", .{@tagName(self.scx_sched)});
        try writer.print("vcache_mode = {s}\n", .{@tagName(self.vcache_mode)});
        try writer.print("profile_mode = {s}\n", .{@tagName(self.profile_mode)});
        try writer.flush();
    }
};
