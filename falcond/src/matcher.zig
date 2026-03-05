const std = @import("std");
const ProfileTable = @import("profiles.zig").ProfileTable;
const scanner = @import("scanner.zig");
const Config = @import("config.zig").Config;
const log = std.log.scoped(.matcher);
pub const no_match = @import("profiles.zig").no_match;

// ── MatchResult ─────────────────────────────────────────────────────────────

pub const MatchResult = struct {
    profile_idx: u8 = no_match,
    is_proton: bool = false,

    pub fn matched(self: MatchResult) bool {
        return self.profile_idx != no_match;
    }
};

// ── matchProcess ────────────────────────────────────────────────────────────

pub fn matchProcess(
    table: *const ProfileTable,
    config: Config,
    pid: u32,
    process_name: []const u8,
) MatchResult {
    // 1. Exact match via hash map
    var hash_hit_proton = false;
    if (table.name_map.get(process_name)) |idx| {
        if (idx != table.proton_index) {
            return .{ .profile_idx = idx };
        }
        hash_hit_proton = true;
    }

    // 2. Case-insensitive fallback scan (skip if hash already found proton)
    if (!hash_hit_proton) {
        if (table.findByName(process_name)) |idx| {
            if (idx != table.proton_index) {
                return .{ .profile_idx = idx };
            }
        }
    }

    // 3. Proton fallback — only for .exe files when a proton profile exists
    if (scanner.isExe(process_name) and table.proton_index != no_match) {
        // Skip known system .exe files (e.g. Wine infrastructure)
        for (config.system_processes) |sys_proc| {
            if (std.ascii.eqlIgnoreCase(process_name, sys_proc)) {
                return .{};
            }
        }

        const is_proton = scanner.isProtonParent(pid) catch false;
        if (is_proton) {
            return .{ .profile_idx = table.proton_index, .is_proton = true };
        }
    }

    // 4. No match
    return .{};
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "MatchResult defaults" {
    const r = MatchResult{};
    try std.testing.expect(!r.matched());
    try std.testing.expectEqual(no_match, r.profile_idx);
    try std.testing.expect(!r.is_proton);
}

test "MatchResult matched returns true when profile set" {
    const r = MatchResult{ .profile_idx = 3 };
    try std.testing.expect(r.matched());
    try std.testing.expect(!r.is_proton);
}

test "MatchResult proton match" {
    const r = MatchResult{ .profile_idx = 1, .is_proton = true };
    try std.testing.expect(r.matched());
    try std.testing.expect(r.is_proton);
}
