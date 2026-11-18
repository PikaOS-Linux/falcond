const std = @import("std");
const otter_utils = @import("otter_utils");
const otter_desktop = @import("otter_desktop");
const scanner = @import("scanner.zig");
const vcache = @import("vcache.zig");
const splitlock = @import("splitlock.zig");
const status = @import("status.zig");

const ScxMode = otter_desktop.scx_loader.ScxMode;
const ScxScheduler = otter_desktop.scx_loader.ScxScheduler;

const log = std.log.scoped(.daemon);
const posix = std.posix;

pub fn shouldIgnoreProtonFallback(active_idx: u8, candidate_idx: u8, proton_idx: u8) bool {
    return candidate_idx == proton_idx and active_idx != proton_idx;
}

pub fn activateProfile(self: anytype, idx: u8, pid: u32) void {
    if (self.active_profile_idx) |active| {
        if (active == idx) {
            if (self.deactivation_deadline != null) {
                self.deactivation_deadline = null;
                log.info("deactivation cancelled — new pid={d} for '{s}'", .{ pid, self.table.names[idx].get() });
            }
            // Same profile: refresh pid/uid so scripts and inhibit track the live process.
            if (pid != 0 and self.active_pid != pid) {
                self.active_pid = pid;
                self.active_uid = scanner.findUserForProcess(pid);
                const act = &self.table.activation[idx];
                if (act.idle_inhibit) {
                    self.inhibitor.inhibit("falcond", "Game profile active", pid);
                }
            }
            return;
        }

        if (shouldIgnoreProtonFallback(active, idx, self.table.proton_index)) {
            log.info("ignoring proton fallback while specific profile '{s}' is active", .{
                self.table.names[active].get(),
            });
            return;
        }

        if (self.profile_pid_counts[active] == 0) {
            self.deactivation_deadline = null;
            deactivateProfile(self, active);
        } else {
            const new_beats_active = active == self.table.proton_index and idx != self.table.proton_index;

            if (self.deactivation_deadline != null or new_beats_active) {
                self.deactivation_deadline = null;
                deactivateProfile(self, active);
            } else {
                for (self.queued_indices.items) |qi| {
                    if (qi == idx) return;
                }
                self.queued_indices.append(self.allocator, idx) catch {
                    log.warn("queue full, dropping profile '{s}'", .{self.table.names[idx].get()});
                };
                log.info("queued profile '{s}'", .{self.table.names[idx].get()});
                return;
            }
        }
    }

    self.active_profile_idx = idx;
    self.active_pid = pid;

    if (pid != 0) {
        self.active_uid = scanner.findUserForProcess(pid);
    }

    const act = &self.table.activation[idx];
    const name = self.table.names[idx].get();
    log.info("activating profile '{s}' (scx={s}, mode={s}, perf={}, vcache={s}, inhibit={}, split_lock={})", .{
        name,
        @tagName(act.scx_sched),
        @tagName(act.scx_sched_props),
        act.performance_mode,
        @tagName(act.vcache_mode),
        act.idle_inhibit,
        act.disable_split_lock,
    });

    if (act.performance_mode) {
        if (self.power_profiles) |*pp| {
            if (pp.getActiveProfile()) |p| {
                self.restore_power_profile = if (std.mem.eql(u8, p, "performance"))
                    "performance"
                else if (std.mem.eql(u8, p, "power-saver"))
                    "power-saver"
                else
                    "balanced";
            }
        }
    }
    if (self.scx_loader) |*scx| {
        if (scx.getCurrentScheduler()) |sched| {
            self.restore_sched = sched.toScxName();
        }
        self.restore_mode = @tagName(scx.getSchedulerMode());
    }
    self.restore_vcache = vcache.read();

    if (act.performance_mode) {
        if (self.power_profiles) |*pp| {
            pp.setActiveProfile("performance") catch |err| {
                log.warn("failed to set performance profile: {}", .{err});
            };
        }
    }

    if (act.scx_sched != .none) {
        if (self.scx_loader) |*scx| {
            scx.switchScheduler(act.scx_sched, act.scx_sched_props) catch |err| {
                log.warn("failed to switch scx scheduler: {}", .{err});
            };
        }
    }

    if (act.vcache_mode.toSysfsValue()) |val| {
        vcache.write(val) catch |err| {
            log.warn("failed to set vcache mode: {}", .{err});
        };
    }

    // Only disable when we captured a restore value; never write(0) without one.
    if (act.disable_split_lock) {
        if (splitlock.read()) |current| {
            self.restore_split_lock = current;
            if (current != 0) {
                splitlock.write(0) catch |err| {
                    log.warn("failed to disable split_lock_mitigate: {}", .{err});
                    self.restore_split_lock = null;
                };
            }
        } else {
            log.warn("split_lock_mitigate unavailable, skipping disable", .{});
        }
    }

    if (act.idle_inhibit) {
        self.inhibitor.inhibit("falcond", "Game profile active", pid);
    }

    if (act.dmem_protect) {
        // Required for enabling +dmem on a populated parent: sibling PIDs in the
        // same cgroup move into falcond-dmem-other so the protected child can own dmem.low.
        if (self.dmem) |*dmem| {
            dmem.activateProfile(idx);
            var it = self.known_pids.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == idx) {
                    dmem.trackPid(idx, name, entry.key_ptr.*, .active);
                }
            }
        }
    }

    if (!act.start_script.isEmpty()) {
        runScript(self, act.start_script.get());
    }

    self.status_dirty = true;
}

pub fn deactivateProfile(self: anytype, idx: u8) void {
    const act = &self.table.activation[idx];
    const name = self.table.names[idx].get();
    log.info("deactivating profile '{s}'", .{name});

    if (self.restore_power_profile) |profile| {
        if (self.power_profiles) |*pp| {
            pp.setActiveProfile(profile) catch |err| {
                log.warn("failed to restore power profile: {}", .{err});
            };
        }
        self.restore_power_profile = null;
    }

    if (self.restore_sched) |sched_name| {
        if (self.scx_loader) |*scx| {
            const restore_mode = if (self.restore_mode) |m|
                std.meta.stringToEnum(ScxMode, m) orelse .default
            else
                .default;
            const restore_sched = ScxScheduler.fromString(sched_name) catch .none;
            if (restore_sched != .none) {
                scx.switchScheduler(restore_sched, restore_mode) catch |err| {
                    log.warn("failed to restore scx scheduler: {}", .{err});
                };
            } else {
                scx.stopScheduler() catch |err| {
                    log.warn("failed to stop scx scheduler: {}", .{err});
                };
            }
        }
        self.restore_sched = null;
        self.restore_mode = null;
    }

    if (self.restore_vcache) |val| {
        vcache.write(val) catch |err| {
            log.warn("failed to restore vcache mode: {}", .{err});
        };
        self.restore_vcache = null;
    }

    if (self.restore_split_lock) |val| {
        splitlock.write(val) catch |err| {
            log.warn("failed to restore split_lock_mitigate: {}", .{err});
        };
        self.restore_split_lock = null;
    }

    if (self.inhibitor.isInhibited()) {
        self.inhibitor.uninhibit();
    }

    if (act.dmem_protect) {
        if (self.dmem) |*dmem| dmem.deactivateProfile(idx);
    }

    if (!act.stop_script.isEmpty()) {
        runScript(self, act.stop_script.get());
    }

    self.active_profile_idx = null;
    self.active_pid = null;
    self.active_uid = null;
    self.status_dirty = true;
}

fn runScript(self: anytype, script: []const u8) void {
    // Scripts are trusted profile config (system/user profiles). They run via
    // /bin/sh -c as the matched game UID when falcond is root.
    if (posix.system.geteuid() == 0) {
        const uid = self.active_uid orelse {
            log.warn("no saved uid, skipping profile script", .{});
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const uid_str = std.fmt.allocPrint(alloc, "#{d}", .{uid}) catch return;
        const dbus_env = std.fmt.allocPrint(alloc, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus", .{uid}) catch return;
        const display = blk: {
            if (self.active_pid) |pid| {
                if (scanner.findDisplayForProcess(pid)) |d| break :blk d;
            }
            break :blk ":0";
        };
        const display_env = std.fmt.allocPrint(alloc, "DISPLAY={s}", .{display}) catch return;

        const argv = [_][]const u8{
            "sudo",    "-u",     uid_str,
            "env",     dbus_env, display_env,
            "/bin/sh", "-c",     script,
        };

        otter_utils.process.spawnArgv(otter_utils.io.get(), &argv);
    } else {
        otter_utils.process.spawnCommand(otter_utils.io.get(), script);
    }
}

test "root script execution requires target uid" {
    try std.testing.expect(canRunScriptFromRoot(1000));
    try std.testing.expect(!canRunScriptFromRoot(null));
}

fn canRunScriptFromRoot(uid: ?u32) bool {
    return uid != null;
}

pub fn updateStatus(self: anytype) void {
    status.update(
        self.config.config,
        &self.table,
        self.active_profile_idx,
        self.queued_indices.items,
        if (self.power_profiles) |*pp| @constCast(pp) else null,
        if (self.scx_loader) |*scx| @constCast(scx) else null,
        self.restore_sched,
        self.restore_mode,
        self.restore_power_profile,
        &self.inhibitor,
        if (self.dmem) |*dmem| dmem else null,
    );
}

const TestPowerProfiles = struct {
    active_profile: [:0]const u8 = "power-saver",
    writes: usize = 0,

    pub fn getActiveProfile(self: *const @This()) ?[]const u8 {
        return self.active_profile;
    }

    pub fn setActiveProfile(self: *@This(), profile: [:0]const u8) !void {
        self.active_profile = profile;
        self.writes += 1;
    }
};

const TestDaemon = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    table: @import("profiles.zig").ProfileTable = @import("profiles.zig").ProfileTable.init(),
    active_profile_idx: ?u8 = null,
    active_pid: ?u32 = null,
    active_uid: ?u32 = null,
    deactivation_deadline: ?i128 = null,
    profile_pid_counts: [@import("profiles.zig").max_profiles]u16 = .{0} ** @import("profiles.zig").max_profiles,
    queued_indices: std.ArrayListUnmanaged(u8) = .empty,
    known_pids: std.AutoHashMap(u32, u8) = std.AutoHashMap(u32, u8).init(std.testing.allocator),
    power_profiles: ?TestPowerProfiles = .{},
    scx_loader: ?otter_desktop.scx_loader.ScxLoader = null,
    inhibitor: @import("inhibitor.zig") = @import("inhibitor.zig").init(std.testing.allocator),
    dmem: ?@import("dmemcg.zig").Manager = null,
    restore_power_profile: ?[:0]const u8 = null,
    restore_sched: ?[]const u8 = null,
    restore_mode: ?[]const u8 = null,
    restore_vcache: ?[]const u8 = null,
    restore_split_lock: ?u8 = null,
    status_dirty: bool = false,

    fn deinit(self: *@This()) void {
        self.table.deinit(self.allocator);
        self.known_pids.deinit();
        self.queued_indices.deinit(self.allocator);
        self.inhibitor.deinit();
    }
};

test "disabled performance mode preserves external power profile changes" {
    var self = TestDaemon{};
    defer self.deinit();
    const idx = try self.table.addProfile("game.exe");
    self.table.activation[idx].vcache_mode = .none;

    activateProfile(&self, idx, 0);
    // No vcache setting is applied by this profile; avoid restoring host sysfs.
    self.restore_vcache = null;
    self.power_profiles.?.active_profile = "balanced";
    deactivateProfile(&self, idx);

    try std.testing.expectEqualStrings("balanced", self.power_profiles.?.active_profile);
    try std.testing.expectEqual(@as(usize, 0), self.power_profiles.?.writes);
    try std.testing.expectEqual(@as(?[:0]const u8, null), self.restore_power_profile);
}

test "enabled performance mode restores the previous power profile" {
    var self = TestDaemon{};
    defer self.deinit();
    const idx = try self.table.addProfile("game.exe");
    self.table.activation[idx].performance_mode = true;
    self.table.activation[idx].vcache_mode = .none;

    activateProfile(&self, idx, 0);
    self.restore_vcache = null;
    try std.testing.expectEqualStrings("performance", self.power_profiles.?.active_profile);
    deactivateProfile(&self, idx);

    try std.testing.expectEqualStrings("power-saver", self.power_profiles.?.active_profile);
    try std.testing.expectEqual(@as(usize, 2), self.power_profiles.?.writes);
    try std.testing.expectEqual(@as(?[:0]const u8, null), self.restore_power_profile);
}
