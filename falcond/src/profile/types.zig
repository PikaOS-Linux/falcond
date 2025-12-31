const std = @import("std");
const vcache_setting = @import("../clients/vcache_setting.zig");
const scx_scheds = @import("../clients/scx_scheds.zig");

pub const Profile = struct {
    name: []const u8,
    performance_mode: bool = false,
    scx_sched: scx_scheds.ScxScheduler = .none,
    scx_sched_props: ?scx_scheds.ScxSchedModes = null,
    vcache_mode: vcache_setting.VCacheMode = .cache,
    start_script: ?[]const u8 = null,
    stop_script: ?[]const u8 = null,
    idle_inhibit: bool = false,

    pub fn matches(self: *const Profile, process_name: []const u8) bool {
        const is_match = std.ascii.eqlIgnoreCase(self.name, process_name);
        if (is_match) {
            std.log.info("Found match: {s} for process {s}", .{ self.name, process_name });
        }
        return is_match;
    }
};

pub const CacheEntry = struct {
    pid: u32,
    timestamp: i64,
    is_proton: bool,
};
