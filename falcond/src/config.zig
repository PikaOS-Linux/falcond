const std = @import("std");
const otter_conf = @import("otter_conf");
const otter_desktop = @import("otter_desktop");
const otter_utils = @import("otter_utils");
const build_options = @import("build_options");
pub const ScxScheduler = otter_desktop.scx_loader.ScxScheduler;
pub const ScxMode = otter_desktop.scx_loader.ScxMode;
inline fn io_global() std.Io {
    return otter_utils.io.get();
}

const log = std.log.scoped(.config);

// ── Paths (configurable via build options, zero runtime cost) ───────────────

pub const default_config_path: []const u8 = build_options.config_path;
pub const default_profiles_dir: []const u8 = build_options.profiles_dir;
pub const user_profiles_dir: []const u8 = build_options.user_profiles_dir;
pub const system_conf_path: []const u8 = build_options.system_conf_path;

// ── Enums ───────────────────────────────────────────────────────────────────

pub const ProfileMode = enum {
    none,
    handheld,
    htpc,
};

pub const VCacheMode = enum {
    cache,
    freq,
    none,

    /// Returns the sysfs string representation, or null for `.none`.
    pub fn toSysfsValue(self: VCacheMode) ?[]const u8 {
        return switch (self) {
            .none => null,
            .freq => "frequency",
            .cache => "cache",
        };
    }
};

// ── Config ──────────────────────────────────────────────────────────────────

pub const Config = struct {
    enable_performance_mode: bool = true,
    scx_sched: ScxScheduler = .none,
    scx_sched_props: ScxMode = .default,
    vcache_mode: VCacheMode = .none,
    system_processes: []const []const u8 = &.{},
    profile_mode: ProfileMode = .none,
    poll_interval_ms: u32 = 9000,
};

// ── LoadedConfig ────────────────────────────────────────────────────────────

pub const LoadedConfig = struct {
    config: Config,
    mtime_ns: i128,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LoadedConfig) void {
        otter_conf.freeConfig(Config, self.allocator, &self.config);
    }
};

// ── Public API ──────────────────────────────────────────────────────────────

const SystemConfig = struct {
    system_processes: []const []const u8 = &.{},
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !LoadedConfig {
    if (std.Io.Dir.path.dirname(path)) |config_dir| {
        std.Io.Dir.createDirAbsolute(io_global(), config_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                log.err("failed to create config directory {s}: {}", .{ config_dir, err });
                return err;
            },
        };
    }

    const created = otter_conf.ensureConfigExists(Config, allocator, path, .{}) catch |err| {
        log.err("failed to initialize config: {s} - {}", .{ path, err });
        return err;
    };
    if (created) {
        log.warn("config file not found: {s}, wrote defaults", .{path});
    }

    const result = otter_conf.loadWithMetadata(Config, allocator, path, .{}) catch |err| {
        log.err("failed to load config: {s} - {}", .{ path, err });
        return err;
    };

    var config = result.config;

    // Load system_processes from the separate system.conf if the main config doesn't define them
    if (config.system_processes.len == 0) {
        if (otter_conf.load(SystemConfig, allocator, system_conf_path, .{})) |sys| {
            config.system_processes = sys.system_processes;
            log.info("loaded {d} system processes from {s}", .{ sys.system_processes.len, system_conf_path });
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => log.warn("failed to load system.conf: {}", .{err}),
            }
        }
    }

    return .{
        .config = config,
        .mtime_ns = result.mtime_ns,
        .allocator = allocator,
    };
}

pub fn hasChanged(path: []const u8, last_mtime_ns: i128) !bool {
    return otter_conf.hasChanged(path, last_mtime_ns);
}

/// Check if a directory's mtime has changed. Returns the new mtime, or null on error.
pub fn dirMtime(path: []const u8) ?i128 {
    var dir = std.Io.Dir.openDirAbsolute(io_global(), path, .{}) catch return null;
    defer dir.close(io_global());
    const stat = dir.stat(io_global()) catch return null;
    return stat.mtime;
}

/// Returns the profile loading directory based on mode.
/// .none => base_path, .handheld => base_path/handheld, .htpc => base_path/htpc
pub fn profilesDirForMode(allocator: std.mem.Allocator, base_path: []const u8, mode: ProfileMode) ![]const u8 {
    return switch (mode) {
        .none => try allocator.dupe(u8, base_path),
        inline .handheld, .htpc => |m| try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, @tagName(m) }),
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "Config defaults" {
    const cfg = Config{};
    try std.testing.expectEqual(ProfileMode.none, cfg.profile_mode);
    try std.testing.expectEqual(true, cfg.enable_performance_mode);
    try std.testing.expectEqual(@as(usize, 0), cfg.system_processes.len);
    try std.testing.expectEqual(VCacheMode.none, cfg.vcache_mode);
    try std.testing.expectEqual(ScxScheduler.none, cfg.scx_sched);
    try std.testing.expectEqual(ScxMode.default, cfg.scx_sched_props);
}

test "VCacheMode sysfs values" {
    try std.testing.expectEqual(@as(?[]const u8, null), VCacheMode.none.toSysfsValue());
    try std.testing.expectEqualStrings("frequency", VCacheMode.freq.toSysfsValue().?);
    try std.testing.expectEqualStrings("cache", VCacheMode.cache.toSysfsValue().?);
}

test "profilesDirForMode" {
    const base = "/usr/share/falcond/profiles";
    const none_dir = try profilesDirForMode(std.testing.allocator, base, .none);
    defer std.testing.allocator.free(none_dir);
    try std.testing.expectEqualStrings(base, none_dir);

    const handheld_dir = try profilesDirForMode(std.testing.allocator, base, .handheld);
    defer std.testing.allocator.free(handheld_dir);
    try std.testing.expectEqualStrings("/usr/share/falcond/profiles/handheld", handheld_dir);
}

test "load creates missing config with defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}/{s}", .{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(rel_dir);
    const rel_dir_z = try std.testing.allocator.dupeZ(u8, rel_dir);
    defer std.testing.allocator.free(rel_dir_z);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_dir = std.mem.sliceTo(std.c.realpath(rel_dir_z, &real_buf) orelse return error.RealPathFailed, 0);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.conf", .{abs_dir});
    defer std.testing.allocator.free(path);

    var loaded = try load(std.testing.allocator, path);
    defer loaded.deinit();

    try std.Io.Dir.accessAbsolute(io_global(), path, .{});
    try std.testing.expectEqual(ProfileMode.none, loaded.config.profile_mode);
    try std.testing.expectEqual(true, loaded.config.enable_performance_mode);
}
