const std = @import("std");
const fs = std.fs;
const confloader = @import("confloader.zig");
const vcache_setting = @import("../clients/vcache_setting.zig");
const scx_scheds = @import("../clients/scx_scheds.zig");

const default_system_processes = [_][]const u8{
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
    "CrashReportClient.exe",
    "Battle.net.exe",
    "Agent.exe",
};

pub const Config = struct {
    enable_performance_mode: bool = true,
    scx_sched: scx_scheds.ScxScheduler = .none,
    scx_sched_props: ?scx_scheds.ScxSchedModes = null,
    vcache_mode: vcache_setting.VCacheMode = .none,
    system_processes: []const []const u8 = &default_system_processes,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
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

        try file.writer().print("enable_performance_mode = {}\n", .{self.enable_performance_mode});
        try file.writer().print("scx_sched = {s}\n", .{@tagName(self.scx_sched)});
        try file.writer().print("vcache_mode = {s}\n", .{@tagName(self.vcache_mode)});

        try file.writer().print("system_processes = [\n", .{});
        for (self.system_processes) |proc| {
            try file.writer().print("  \"{s}\",\n", .{proc});
        }
        try file.writer().print("]\n", .{});
    }
};
