const std = @import("std");
const fs = std.fs;
const confloader = @import("confloader.zig");
const vcache_setting = @import("vcache_setting.zig");
const scx_scheds = @import("scx_scheds.zig");

pub const Config = struct {
    enable_performance_mode: bool = true,
    scx_sched: scx_scheds.ScxScheduler = .none,
    scx_sched_props: ?scx_scheds.ScxSchedModes = null,
    vcache_mode: vcache_setting.VCacheMode = .none,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const config_path = "/etc/falcond/config.conf";
        var config = Config{};
        const file = fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try config.save();
                return config;
            },
            else => return err,
        };
        defer file.close();

        config = try confloader.loadConf(Config, allocator, config_path);
        return config;
    }

    pub fn save(self: Config) !void {
        const config_dir = "/etc/falcond/";

        fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var file_buf: [fs.max_path_bytes]u8 = undefined;
        const config_path = try std.fmt.bufPrint(
            &file_buf,
            "{s}/config.conf",
            .{config_dir},
        );

        const file = try fs.createFileAbsolute(config_path, .{});
        defer file.close();

        try file.writer().print("enable_performance_mode = {}\n", .{self.enable_performance_mode});
        try file.writer().print("scx_sched = {s}\n", .{@tagName(self.scx_sched)});
        try file.writer().print("vcache_mode = {s}\n", .{@tagName(self.vcache_mode)});
    }
};
