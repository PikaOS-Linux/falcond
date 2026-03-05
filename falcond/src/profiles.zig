const std = @import("std");
const otter_conf = @import("otter_conf");
const otter_desktop = @import("otter_desktop");
const ScxScheduler = otter_desktop.scx_loader.ScxScheduler;
const ScxMode = otter_desktop.scx_loader.ScxMode;
const config_mod = @import("config.zig");
const VCacheMode = config_mod.VCacheMode;
const ProfileMode = config_mod.ProfileMode;
const log = std.log.scoped(.profiles);

// ── Constants ────────────────────────────────────────────────────────────────

pub const max_profiles = 64;
pub const max_name_len = 128;
pub const max_script_len = 512;
pub const no_match: u8 = max_profiles;
pub const default_profiles_dir = config_mod.default_profiles_dir;
pub const user_profiles_dir = config_mod.user_profiles_dir;

// ── FixedStr ─────────────────────────────────────────────────────────────────

pub fn FixedStr(comptime max_len: usize) type {
    return struct {
        const Self = @This();

        data: [max_len]u8 = undefined,
        len: u8 = 0,

        pub fn set(self: *Self, value: []const u8) void {
            const clamped = @min(value.len, max_len);
            if (value.len > max_len) {
                log.warn("truncating '{s}' to {d} bytes", .{ value[0..@min(value.len, 256)], max_len });
            }
            @memcpy(self.data[0..clamped], value[0..clamped]);
            self.len = @intCast(clamped);
        }

        pub fn get(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            return std.mem.eql(u8, self.get(), other.get());
        }
    };
}

// ── ActivationData ───────────────────────────────────────────────────────────

pub const ActivationData = struct {
    performance_mode: bool = false,
    scx_sched: ScxScheduler = .none,
    scx_sched_props: ScxMode = .default,
    vcache_mode: VCacheMode = .cache,
    start_script: FixedStr(max_script_len) = .{},
    stop_script: FixedStr(max_script_len) = .{},
    idle_inhibit: bool = false,
};

// ── ProfileTable ─────────────────────────────────────────────────────────────

pub const ProfileTable = struct {
    const Self = @This();

    /// Each profile has a single name — also used as the process match name.
    names: [max_profiles]FixedStr(max_name_len),
    activation: [max_profiles]ActivationData,
    count: u8 = 0,
    proton_index: u8 = no_match,
    /// Maps process name → profile index for fast lookup.
    name_map: std.StringHashMapUnmanaged(u8) = .{},

    pub fn init() ProfileTable {
        return .{
            .names = [_]FixedStr(max_name_len){.{}} ** max_profiles,
            .activation = [_]ActivationData{.{}} ** max_profiles,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.name_map.deinit(allocator);
    }

    pub fn addProfile(self: *Self, name: []const u8) !u8 {
        if (self.count >= max_profiles) return error.TooManyProfiles;
        const idx = self.count;
        self.names[idx].set(name);
        self.count += 1;
        return idx;
    }

    /// Find an existing profile by name (case-insensitive).
    pub fn findByName(self: *const Self, name: []const u8) ?u8 {
        for (0..self.count) |i| {
            if (std.ascii.eqlIgnoreCase(self.names[i].get(), name)) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Rebuild the hash map after adding/removing profiles.
    pub fn rebuildNameMap(self: *Self, allocator: std.mem.Allocator) !void {
        self.name_map.clearRetainingCapacity();
        for (0..self.count) |i| {
            const key = self.names[i].get();
            // Keys point into FixedStr storage so they stay valid.
            try self.name_map.put(allocator, key, @intCast(i));
        }
    }
};

// ── ProfileConfig ─────────────────────────────────────────────────────────────

pub const ProfileConfig = struct {
    name: []const u8 = "",
    performance_mode: bool = false,
    scx_sched: ScxScheduler = .none,
    scx_sched_props: ScxMode = .default,
    vcache_mode: VCacheMode = .cache,
    start_script: []const u8 = "",
    stop_script: []const u8 = "",
    idle_inhibit: bool = false,
};

// ── loadProfiles ─────────────────────────────────────────────────────────────

pub fn loadProfiles(allocator: std.mem.Allocator, table: *ProfileTable, dir_path: []const u8) !void {
    var result = otter_conf.loadDir(ProfileConfig, allocator, dir_path, .{
        .extension = ".conf",
        .recursive = false,
    }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.debug("profiles directory not found: {s}", .{dir_path});
                return;
            },
            else => {
                log.err("failed to access profiles directory: {s} - {}", .{ dir_path, err });
                return err;
            },
        }
    };
    defer result.deinit(true);

    for (result.entries) |entry| {
        const cfg = entry.config;

        const idx = table.addProfile(cfg.name) catch |err| {
            log.warn("could not add profile '{s}': {}", .{ cfg.name, err });
            continue;
        };

        if (std.ascii.eqlIgnoreCase(cfg.name, "proton")) {
            table.proton_index = idx;
        }

        var act = &table.activation[idx];
        act.performance_mode = cfg.performance_mode;
        act.scx_sched = cfg.scx_sched;
        act.scx_sched_props = cfg.scx_sched_props;
        act.vcache_mode = cfg.vcache_mode;
        act.idle_inhibit = cfg.idle_inhibit;

        if (cfg.start_script.len > 0) {
            act.start_script.set(cfg.start_script);
        }
        if (cfg.stop_script.len > 0) {
            act.stop_script.set(cfg.stop_script);
        }

        log.info("loaded profile '{s}'", .{cfg.name});
    }

    try table.rebuildNameMap(allocator);
}

// ── loadUserProfiles ─────────────────────────────────────────────────────────

pub fn loadUserProfiles(allocator: std.mem.Allocator, table: *ProfileTable) !void {
    const user_dir = user_profiles_dir;

    var result = otter_conf.loadDir(ProfileConfig, allocator, user_dir, .{
        .extension = ".conf",
        .recursive = false,
    }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.debug("user profiles directory not found: {s}", .{user_dir});
                return;
            },
            else => {
                log.warn("failed to access user profiles directory: {s} - {}", .{ user_dir, err });
                return;
            },
        }
    };
    defer result.deinit(true);

    var user_count: usize = 0;

    for (result.entries) |entry| {
        const cfg = entry.config;

        const idx = if (table.findByName(cfg.name)) |eidx| blk: {
            log.info("overriding profile '{s}' with user config", .{cfg.name});
            break :blk eidx;
        } else blk: {
            break :blk table.addProfile(cfg.name) catch |err| {
                log.warn("could not add user profile '{s}': {}", .{ cfg.name, err });
                continue;
            };
        };

        if (std.ascii.eqlIgnoreCase(cfg.name, "proton")) {
            table.proton_index = idx;
        }

        var act = &table.activation[idx];
        act.performance_mode = cfg.performance_mode;
        act.scx_sched = cfg.scx_sched;
        act.scx_sched_props = cfg.scx_sched_props;
        act.vcache_mode = cfg.vcache_mode;
        act.idle_inhibit = cfg.idle_inhibit;

        if (cfg.start_script.len > 0) {
            act.start_script.set(cfg.start_script);
        }
        if (cfg.stop_script.len > 0) {
            act.stop_script.set(cfg.stop_script);
        }

        user_count += 1;
    }

    log.info("loaded {d} user profile overrides", .{user_count});
    try table.rebuildNameMap(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "FixedStr basic operations" {
    var s = FixedStr(64){};

    try std.testing.expect(s.isEmpty());

    s.set("hello");
    try std.testing.expect(!s.isEmpty());
    try std.testing.expectEqualStrings("hello", s.get());

    var other = FixedStr(64){};
    other.set("hello");
    try std.testing.expect(s.eql(&other));

    other.set("world");
    try std.testing.expect(!s.eql(&other));
}

test "ProfileTable init and add" {
    var table = ProfileTable.init();
    defer table.deinit(std.testing.allocator);

    const idx = try table.addProfile("Cyberpunk2077.exe");
    try std.testing.expectEqual(@as(u8, 0), idx);
    try std.testing.expectEqualStrings("Cyberpunk2077.exe", table.names[idx].get());
    try std.testing.expectEqual(@as(u8, 1), table.count);
}

test "ProfileTable findByName case-insensitive" {
    var table = ProfileTable.init();
    defer table.deinit(std.testing.allocator);

    _ = try table.addProfile("Proton");

    try std.testing.expectEqual(@as(?u8, 0), table.findByName("Proton"));
    try std.testing.expectEqual(@as(?u8, 0), table.findByName("proton"));
    try std.testing.expectEqual(@as(?u8, 0), table.findByName("PROTON"));
    try std.testing.expectEqual(@as(?u8, null), table.findByName("steam"));
}

test "ProfileTable hash map lookup" {
    var table = ProfileTable.init();
    defer table.deinit(std.testing.allocator);

    _ = try table.addProfile("gamea.exe");
    _ = try table.addProfile("gameb.exe");

    try table.rebuildNameMap(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), table.name_map.get("gamea.exe").?);
    try std.testing.expectEqual(@as(u8, 1), table.name_map.get("gameb.exe").?);
    try std.testing.expectEqual(@as(?u8, null), table.name_map.get("unknown.exe"));
}

test "ActivationData defaults match old Profile defaults" {
    const act = ActivationData{};
    try std.testing.expectEqual(false, act.performance_mode);
    try std.testing.expectEqual(ScxScheduler.none, act.scx_sched);
    try std.testing.expectEqual(ScxMode.default, act.scx_sched_props);
    try std.testing.expectEqual(VCacheMode.cache, act.vcache_mode);
    try std.testing.expectEqual(false, act.idle_inhibit);
}
