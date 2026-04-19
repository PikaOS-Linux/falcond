const std = @import("std");
const otter_desktop = @import("otter_desktop");
const otter_utils = @import("otter_utils");
const PowerProfiles = otter_desktop.PowerProfiles;
const ScxLoader = otter_desktop.scx_loader.ScxLoader;
const ScxScheduler = otter_desktop.scx_loader.ScxScheduler;
const ScxMode = otter_desktop.scx_loader.ScxMode;
const Inhibitor = @import("inhibitor.zig");

const config_mod = @import("config.zig");
const Config = config_mod.Config;
const ProfileMode = config_mod.ProfileMode;
const profiles_mod = @import("profiles.zig");
const ProfileTable = profiles_mod.ProfileTable;
const scanner = @import("scanner.zig");
const matcher_mod = @import("matcher.zig");
const MatchResult = matcher_mod.MatchResult;
const EventLoop = @import("event_loop.zig");
const daemon_actions = @import("daemon_actions.zig");

const log = std.log.scoped(.daemon);
const posix = std.posix;

const Self = @This();

allocator: std.mem.Allocator,
config: config_mod.LoadedConfig,
table: ProfileTable,
active_profile_idx: ?u8 = null,
active_pid: ?u32 = null,
active_uid: ?u32 = null,
queued_indices: std.ArrayListUnmanaged(u8) = .empty,
reload_preferred_profile: profiles_mod.FixedStr(profiles_mod.max_name_len) = .{},
known_pids: std.AutoHashMap(u32, u8),
profile_pid_counts: [profiles_mod.max_profiles]u16 = .{0} ** profiles_mod.max_profiles,
power_profiles: ?PowerProfiles = null,
scx_loader: ?ScxLoader = null,
inhibitor: Inhibitor,
restore_sched: ?[]const u8 = null,
restore_mode: ?[]const u8 = null,
restore_vcache: ?[]const u8 = null,
restore_power_profile: ?[:0]const u8 = null,
profiles_dir: []const u8,
event_loop: EventLoop,
pending_rechecks: PendingRechecks = .{},
deactivation_deadline: ?i128 = null,
last_full_scan_ns: i128 = 0,
last_reload_ns: i128 = 0,
status_dirty: bool = true,
oneshot: bool,

const PendingRecheck = struct { pid: u32, deadline_ns: i128, retries: u8 };
const PendingRechecks = otter_utils.BoundedArray(PendingRecheck, 32);
const recheck_delay_ns: i128 = 100 * std.time.ns_per_ms;
const max_rechecks: u8 = 15;
const deactivation_grace_ns: i128 = 3000 * std.time.ns_per_ms;
const reload_debounce_ns: i128 = 1000 * std.time.ns_per_ms;
const TrackAction = enum { unchanged, inserted, reassigned };
const ReleaseReason = enum { exec, exit, scan };
const generic_proton_child_comms = [_][]const u8{
    "GameThread",
};

pub fn init(allocator: std.mem.Allocator, config_path: []const u8, oneshot: bool) !Self {
    scanner.initProcFd();

    var loaded = try config_mod.load(allocator, config_path);
    errdefer loaded.deinit();

    log.info("config loaded", .{});

    var table = ProfileTable.init();
    errdefer table.deinit(allocator);

    const profiles_dir = try config_mod.profilesDirForMode(
        allocator,
        config_mod.default_profiles_dir,
        loaded.config.profile_mode,
    );
    errdefer allocator.free(profiles_dir);

    profiles_mod.loadProfiles(allocator, &table, profiles_dir) catch |err| {
        log.err("failed to load profiles: {}", .{err});
    };

    profiles_mod.loadUserProfiles(allocator, &table) catch |err| {
        log.warn("failed to load user profiles: {}", .{err});
    };

    log.info("loaded {d} profiles (mode: {s})", .{ table.count, @tagName(loaded.config.profile_mode) });

    const power_profiles: ?PowerProfiles = if (loaded.config.enable_performance_mode)
        PowerProfiles.init(allocator) catch |err| blk: {
            log.warn("power profiles unavailable: {}", .{err});
            break :blk null;
        }
    else
        null;

    const scx_loader: ?ScxLoader = ScxLoader.init(allocator) catch |err| blk: {
        log.warn("scx_loader unavailable: {}", .{err});
        break :blk null;
    };

    var event_loop = if (!oneshot)
        try EventLoop.init(allocator, config_path, profiles_dir)
    else
        undefined;
    errdefer if (!oneshot) event_loop.deinit();

    var self = Self{
        .allocator = allocator,
        .config = loaded,
        .table = table,
        .known_pids = std.AutoHashMap(u32, u8).init(allocator),
        .power_profiles = power_profiles,
        .scx_loader = scx_loader,
        .inhibitor = Inhibitor.init(allocator),
        .profiles_dir = profiles_dir,
        .event_loop = event_loop,
        .oneshot = oneshot,
    };

    if (loaded.config.vcache_mode.toSysfsValue()) |val| {
        @import("vcache.zig").write(val) catch |err| {
            log.warn("failed to set global vcache mode: {}", .{err});
        };
    }

    if (loaded.config.scx_sched != .none) {
        if (self.scx_loader) |*scx| {
            scx.switchScheduler(loaded.config.scx_sched, loaded.config.scx_sched_props) catch |err| {
                log.warn("failed to set global scx scheduler: {}", .{err});
            };
        }
    }

    daemon_actions.updateStatus(self);
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.active_profile_idx) |idx| {
        daemon_actions.deactivateProfile(self, idx);
    }

    daemon_actions.updateStatus(self);

    if (!self.oneshot) self.event_loop.deinit();
    self.inhibitor.deinit();
    if (self.scx_loader) |*scx| {
        scx.deinit();
    }
    if (self.power_profiles) |*pp| {
        pp.deinit();
    }
    self.allocator.free(self.profiles_dir);
    self.queued_indices.deinit(self.allocator);
    self.known_pids.deinit();
    self.table.deinit(self.allocator);
    self.config.deinit();
    scanner.deinitProcFd();
}

pub fn run(self: *Self) !void {
    if (self.oneshot) {
        self.handleProcesses();
        return;
    }

    self.event_loop.tracked_pids = &self.known_pids;
    self.event_loop.profile_pid_counts = &self.profile_pid_counts;

    self.handleProcesses();
    self.status_dirty = true;

    while (true) {
        const timeout = self.computeTimeout();
        const events = self.event_loop.wait(timeout);

        for (events.constSlice()) |event| {
            switch (event) {
                .signal_term => {
                    log.info("received SIGTERM, shutting down", .{});
                    return;
                },
                .signal_hup => {
                    log.info("received SIGHUP, reloading", .{});
                    self.reload() catch |err| {
                        log.err("reload failed: {}", .{err});
                    };
                    daemon_actions.updateStatus(self);
                    self.handleProcesses();
                    self.last_reload_ns = nowNs();
                    self.status_dirty = true;
                },
                .config_changed => {
                    const now = nowNs();
                    if (now - self.last_reload_ns >= reload_debounce_ns) {
                        log.info("config or profiles changed, reloading", .{});
                        self.reload() catch |err| {
                            log.err("reload failed: {}", .{err});
                        };
                        daemon_actions.updateStatus(self);
                        self.handleProcesses();
                        self.last_reload_ns = now;
                        self.status_dirty = true;
                    } else {
                        log.debug("config change debounced", .{});
                    }
                },
                .proc_fork => |info| {
                    self.handleForkEvent(info.parent, info.child);
                    self.status_dirty = true;
                },
                .proc_exec => |pid| self.handleExecEvent(pid),
                .proc_exit => |pid| self.handleExitEvent(pid),
                .timeout => {
                    const now = nowNs();
                    const interval_ns = @as(i128, self.config.config.poll_interval_ms) * std.time.ns_per_ms;
                    if (now - self.last_full_scan_ns >= interval_ns) {
                        self.handleProcesses();
                        self.status_dirty = true;
                        self.last_full_scan_ns = now;
                    }
                },
            }
        }

        if (self.pending_rechecks.len > 0) {
            self.processPendingRechecks();
        }

        self.ensureActiveProfileGrace();
        self.checkDeactivationGrace();

        if (self.status_dirty) {
            daemon_actions.updateStatus(self);
            self.status_dirty = false;
        }
    }
}

fn handleForkEvent(self: *Self, parent: u32, child: u32) void {
    self.deactivation_deadline = null;
    self.queueRecheck(child, max_rechecks);
    if (self.active_pid != null and self.active_pid.? == parent) {
        self.active_pid = child;
        self.active_uid = scanner.findUserForProcess(child);
    }
}

fn handleExecEvent(self: *Self, pid: u32) void {
    if (pid <= 2) return;

    const comm_buf = scanner.getProcessComm(pid) orelse return;
    const comm = std.mem.sliceTo(&comm_buf, 0);
    if (!self.shouldInspectProcess(pid, comm)) return;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const name = scanner.getProcessName(alloc, pid) orelse return;

    if (isWinePreloader(name)) {
        self.queueRecheck(pid, max_rechecks);
        return;
    }

    self.matchAndActivateExec(pid, name);
}

fn isWinePreloader(name: []const u8) bool {
    return std.mem.eql(u8, name, "wine64-preloader") or std.mem.eql(u8, name, "wine-preloader");
}

fn queueRecheck(self: *Self, pid: u32, retries: u8) void {
    const deadline = nowNs() + recheck_delay_ns;
    self.pending_rechecks.append(.{ .pid = pid, .deadline_ns = deadline, .retries = retries }) catch {};
}

fn processPendingRechecks(self: *Self) void {
    const now = nowNs();
    var write: usize = 0;
    for (self.pending_rechecks.constSlice()) |entry| {
        if (now < entry.deadline_ns) {
            self.pending_rechecks.buffer[write] = entry;
            write += 1;
            continue;
        }

        if (self.known_pids.contains(entry.pid)) continue;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const name = scanner.getProcessName(alloc, entry.pid) orelse continue;

        if (isWinePreloader(name)) {
            if (entry.retries > 0) {
                self.queueRecheck(entry.pid, entry.retries - 1);
            } else {
                log.debug("recheck exhausted pid={d}, still '{s}'", .{ entry.pid, name });
            }
            continue;
        }

        if (self.isSystemProcess(name)) continue;

        log.debug("deferred recheck pid={d} name='{s}'", .{ entry.pid, name });
        self.matchAndActivate(entry.pid, name);
    }
    self.pending_rechecks.len = @intCast(write);
}

fn matchAndActivate(self: *Self, pid: u32, name: []const u8) void {
    if (self.isSystemProcess(name)) return;

    const result = matcher_mod.matchProcess(
        &self.table,
        self.config.config,
        pid,
        name,
    );

    if (result.matched()) {
        switch (self.assignTrackedPid(pid, result.profile_idx, true)) {
            .inserted, .reassigned => log.info("matched pid={d} name='{s}' profile='{s}'", .{
                pid, name, self.table.names[result.profile_idx].get(),
            }),
            .unchanged => {},
        }
        daemon_actions.activateProfile(self, result.profile_idx, pid);
    }
}

fn matchAndActivateExec(self: *Self, pid: u32, name: []const u8) void {
    const previous_idx = self.known_pids.get(pid);

    if (self.isSystemProcess(name)) {
        _ = self.releaseTrackedPid(pid, true, .exec);
        return;
    }

    const result = matcher_mod.matchProcess(
        &self.table,
        self.config.config,
        pid,
        name,
    );

    if (!result.matched()) {
        _ = self.releaseTrackedPid(pid, true, .exec);
        return;
    }

    switch (self.assignTrackedPid(pid, result.profile_idx, true)) {
        .unchanged => {},
        .inserted => log.info("matched pid={d} name='{s}' profile='{s}'", .{
            pid, name, self.table.names[result.profile_idx].get(),
        }),
        .reassigned => if (previous_idx) |idx| {
            log.info("rematched pid={d} name='{s}' profile='{s}' -> '{s}'", .{
                pid,
                name,
                self.table.names[idx].get(),
                self.table.names[result.profile_idx].get(),
            });
        },
    }

    daemon_actions.activateProfile(self, result.profile_idx, pid);
}

fn assignTrackedPid(self: *Self, pid: u32, profile_idx: u8, restart_grace: bool) TrackAction {
    const entry = self.known_pids.getOrPut(pid) catch return .unchanged;

    if (entry.found_existing) {
        const previous_idx = entry.value_ptr.*;
        if (previous_idx == profile_idx) return .unchanged;

        entry.value_ptr.* = profile_idx;
        self.profile_pid_counts[previous_idx] -= 1;
        self.beginGraceIfProfileDrained(previous_idx, restart_grace, .exec);
        self.profile_pid_counts[profile_idx] += 1;
        self.status_dirty = true;
        return .reassigned;
    }

    entry.value_ptr.* = profile_idx;
    self.profile_pid_counts[profile_idx] += 1;
    self.status_dirty = true;
    return .inserted;
}

fn releaseTrackedPid(self: *Self, pid: u32, restart_grace: bool, reason: ReleaseReason) ?u8 {
    const profile_idx = self.known_pids.get(pid) orelse return null;
    _ = self.known_pids.remove(pid);
    self.profile_pid_counts[profile_idx] -= 1;
    self.status_dirty = true;
    self.beginGraceIfProfileDrained(profile_idx, restart_grace, reason);
    return profile_idx;
}

fn beginGraceIfProfileDrained(self: *Self, profile_idx: u8, restart: bool, reason: ReleaseReason) void {
    if (self.active_profile_idx) |active_idx| {
        if (active_idx == profile_idx and !self.hasAnyPidForProfile(profile_idx)) {
            if (restart or self.deactivation_deadline == null) {
                self.deactivation_deadline = nowNs() + deactivation_grace_ns;
                log.info("last pid for '{s}' {s}, grace period started", .{
                    self.table.names[profile_idx].get(),
                    releaseReasonText(reason),
                });
            }
        }
    }
}

fn releaseReasonText(reason: ReleaseReason) []const u8 {
    return switch (reason) {
        .exec => "execed away",
        .exit => "exited",
        .scan => "gone from /proc",
    };
}

fn handleExitEvent(self: *Self, pid: u32) void {
    const profile_idx = self.releaseTrackedPid(pid, true, .exit) orelse return;
    log.debug("exit pid={d} profile='{s}'", .{ pid, self.table.names[profile_idx].get() });
}

fn ensureActiveProfileGrace(self: *Self) void {
    const idx = self.active_profile_idx orelse return;
    if (self.hasAnyPidForProfile(idx)) return;
    if (self.deactivation_deadline != null) return;

    self.deactivation_deadline = nowNs() + deactivation_grace_ns;
    log.info("active profile '{s}' has no tracked pids, grace period started", .{
        self.table.names[idx].get(),
    });
}

fn reload(self: *Self) !void {
    var new_config = try config_mod.load(self.allocator, config_mod.default_config_path);
    errdefer new_config.deinit();

    const new_dir = try config_mod.profilesDirForMode(
        self.allocator,
        config_mod.default_profiles_dir,
        new_config.config.profile_mode,
    );
    errdefer self.allocator.free(new_dir);

    if (self.active_profile_idx) |idx| {
        self.reload_preferred_profile.set(self.table.names[idx].get());
    } else {
        self.reload_preferred_profile.len = 0;
    }

    if (self.active_profile_idx) |idx| {
        daemon_actions.deactivateProfile(self, idx);
    }
    self.active_profile_idx = null;
    self.deactivation_deadline = null;
    self.pending_rechecks = .{};
    self.queued_indices.clearRetainingCapacity();
    self.known_pids.clearRetainingCapacity();
    self.profile_pid_counts = .{0} ** profiles_mod.max_profiles;

    self.config.deinit();
    self.config = new_config;

    self.table.deinit(self.allocator);
    self.table = ProfileTable.init();

    self.allocator.free(self.profiles_dir);
    self.profiles_dir = new_dir;

    profiles_mod.loadProfiles(self.allocator, &self.table, self.profiles_dir) catch {};
    profiles_mod.loadUserProfiles(self.allocator, &self.table) catch {};

    if (!self.oneshot) {
        self.event_loop.updateWatches(config_mod.default_config_path, self.profiles_dir);
    }

    log.info("reloaded {d} profiles", .{self.table.count});
}

fn handleProcesses(self: *Self) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var processes = scanner.scanProcesses(alloc) catch |err| {
        log.err("proc scan failed: {}", .{err});
        return;
    };
    defer processes.deinit();

    var alive = std.AutoHashMap(u32, void).init(alloc);

    var best_idx: ?u8 = null;
    var best_pid: u32 = 0;
    var best_is_proton: bool = true;
    const preferred_idx = if (self.reload_preferred_profile.isEmpty())
        null
    else
        self.table.findByName(self.reload_preferred_profile.get());

    var it = processes.iterator();
    while (it.next()) |entry| {
        const pid = entry.key_ptr.*;
        const name = entry.value_ptr.*;

        if (self.reconcileTrackedPidScan(pid, name)) {
            alive.put(pid, {}) catch {};
            continue;
        }

        const comm_buf = scanner.getProcessComm(pid) orelse continue;
        const comm = std.mem.sliceTo(&comm_buf, 0);
        if (!self.shouldInspectProcess(pid, comm)) continue;

        if (self.isSystemProcess(name)) continue;

        const result = matcher_mod.matchProcess(
            &self.table,
            self.config.config,
            pid,
            name,
        );

        if (result.matched()) {
            _ = self.assignTrackedPid(pid, result.profile_idx, false);
            alive.put(pid, {}) catch {};

            if (self.active_profile_idx == null) {
                if (shouldPreferCandidate(&self.table, best_idx, best_pid, best_is_proton, result, pid, preferred_idx)) {
                    best_idx = result.profile_idx;
                    best_pid = pid;
                    best_is_proton = result.is_proton;
                }
            } else {
                daemon_actions.activateProfile(self, result.profile_idx, pid);
            }
        }
    }

    if (self.active_profile_idx == null) {
        if (best_idx) |idx| {
            daemon_actions.activateProfile(self, idx, best_pid);
        }
    }
    self.reload_preferred_profile.len = 0;

    if (!self.oneshot) {
        var to_remove: std.ArrayListUnmanaged(u32) = .empty;
        var kit = self.known_pids.iterator();
        while (kit.next()) |entry| {
            if (!alive.contains(entry.key_ptr.*)) {
                to_remove.append(alloc, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |pid| {
            _ = self.releaseTrackedPid(pid, false, .scan);
        }
    }
}

fn reconcileTrackedPidScan(self: *Self, pid: u32, name: []const u8) bool {
    const tracked_idx = self.known_pids.get(pid) orelse return false;

    if (self.isSystemProcess(name)) {
        _ = self.releaseTrackedPid(pid, false, .scan);
        return false;
    }

    const result = matcher_mod.matchProcess(
        &self.table,
        self.config.config,
        pid,
        name,
    );

    if (!result.matched()) {
        _ = self.releaseTrackedPid(pid, false, .scan);
        return false;
    }

    switch (self.assignTrackedPid(pid, result.profile_idx, false)) {
        .unchanged => {},
        .inserted => unreachable,
        .reassigned => log.info("scan rematched pid={d} name='{s}' profile='{s}' -> '{s}'", .{
            pid,
            name,
            self.table.names[tracked_idx].get(),
            self.table.names[result.profile_idx].get(),
        }),
    }

    if (self.active_profile_idx == null) {
        return true;
    }

    daemon_actions.activateProfile(self, result.profile_idx, pid);
    return true;
}

fn isSystemProcess(self: *Self, name: []const u8) bool {
    if (!scanner.isExe(name)) return false;
    for (self.config.config.system_processes) |sys_proc| {
        if (std.ascii.eqlIgnoreCase(name, sys_proc)) return true;
    }
    return false;
}

fn shouldPreferCandidate(
    table: *const ProfileTable,
    current_idx: ?u8,
    current_pid: u32,
    current_is_proton: bool,
    candidate: MatchResult,
    candidate_pid: u32,
    preferred_idx: ?u8,
) bool {
    const idx = current_idx orelse return true;

    if (preferred_idx) |preferred| {
        const candidate_is_preferred = candidate.profile_idx == preferred;
        const current_is_preferred = idx == preferred;
        if (candidate_is_preferred != current_is_preferred) {
            return candidate_is_preferred;
        }
    }

    if (current_is_proton != candidate.is_proton) {
        return current_is_proton and !candidate.is_proton;
    }

    if (candidate.profile_idx != idx) {
        const candidate_name = table.names[candidate.profile_idx].get();
        const current_name = table.names[idx].get();
        const order = std.mem.order(u8, candidate_name, current_name);
        if (order != .eq) {
            return order == .lt;
        }
    }

    return candidate_pid < current_pid;
}

fn shouldIgnoreProtonFallback(active_idx: u8, candidate_idx: u8, proton_idx: u8) bool {
    return candidate_idx == proton_idx and active_idx != proton_idx;
}

fn hasAnyPidForProfile(self: *Self, profile_idx: u8) bool {
    return self.profile_pid_counts[profile_idx] > 0;
}

fn couldMatch(self: *Self, comm: []const u8) bool {
    if (comm.len == 0) return false;
    if (std.mem.startsWith(u8, comm, "wine")) return true;
    if (std.ascii.indexOfIgnoreCase(comm, ".exe") != null) return true;
    if (comm.len >= 15) return true;
    if (self.table.name_map.get(comm) != null) return true;
    return self.table.findByName(comm) != null;
}

fn isGenericProtonChildComm(comm: []const u8) bool {
    inline for (generic_proton_child_comms) |name| {
        if (std.mem.eql(u8, comm, name)) return true;
    }
    return false;
}

fn shouldInspectProcess(self: *Self, pid: u32, comm: []const u8) bool {
    if (self.couldMatch(comm)) return true;
    if (self.table.proton_index == profiles_mod.no_match) return false;
    if (isGenericProtonChildComm(comm)) return true;
    return scanner.isProtonParent(pid) catch false;
}

fn computeTimeout(self: *Self) u32 {
    if (self.deactivation_deadline != null or self.pending_rechecks.len > 0)
        return 200;
    return self.config.config.poll_interval_ms;
}

fn checkDeactivationGrace(self: *Self) void {
    const deadline = self.deactivation_deadline orelse return;
    if (nowNs() < deadline) return;

    const idx = self.active_profile_idx orelse {
        self.deactivation_deadline = null;
        return;
    };

    if (self.hasAnyPidForProfile(idx)) {
        self.deactivation_deadline = null;
        log.info("profile '{s}' kept alive by remaining processes", .{self.table.names[idx].get()});
        return;
    }

    if (self.pending_rechecks.len > 0) {
        self.deactivation_deadline = nowNs() + deactivation_grace_ns;
        log.debug("extending grace — {d} pending rechecks", .{self.pending_rechecks.len});
        return;
    }

    self.deactivation_deadline = null;
    log.info("grace period expired, deactivating profile '{s}'", .{self.table.names[idx].get()});
    daemon_actions.deactivateProfile(self, idx);

    if (self.queued_indices.items.len > 0) {
        const next = self.queued_indices.orderedRemove(0);
        if (self.findPidForProfile(next)) |next_pid| {
            daemon_actions.activateProfile(self, next, next_pid);
        } else {
            log.info("queued profile '{s}' dropped — process no longer running", .{self.table.names[next].get()});
        }
    }
}

fn findPidForProfile(self: *Self, profile_idx: u8) ?u32 {
    var it = self.known_pids.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == profile_idx) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn nowNs() i128 {
    var ts: posix.timespec = undefined;
    if (posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts) != 0) {
        return 0;
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

test "shouldPreferCandidate prefers specific profile over proton fallback" {
    var table = ProfileTable.init();
    defer table.deinit(std.testing.allocator);

    const proton_idx = try table.addProfile("proton");
    const game_idx = try table.addProfile("Game.exe");
    table.proton_index = proton_idx;

    try std.testing.expect(shouldPreferCandidate(
        &table,
        proton_idx,
        200,
        true,
        .{ .profile_idx = game_idx, .is_proton = false },
        300,
        null,
    ));
}

test "shouldPreferCandidate preserves pre-reload active profile when still running" {
    var table = ProfileTable.init();
    defer table.deinit(std.testing.allocator);

    const alpha_idx = try table.addProfile("Alpha.exe");
    const beta_idx = try table.addProfile("Beta.exe");

    try std.testing.expect(shouldPreferCandidate(
        &table,
        alpha_idx,
        101,
        false,
        .{ .profile_idx = beta_idx, .is_proton = false },
        202,
        beta_idx,
    ));
}

test "shouldIgnoreProtonFallback only blocks generic proton behind specific profiles" {
    try std.testing.expect(shouldIgnoreProtonFallback(3, 1, 1));
    try std.testing.expect(!shouldIgnoreProtonFallback(1, 1, 1));
    try std.testing.expect(!shouldIgnoreProtonFallback(3, 4, 1));
}

test "isGenericProtonChildComm matches known generic proton comm values" {
    try std.testing.expect(isGenericProtonChildComm("GameThread"));
    try std.testing.expect(!isGenericProtonChildComm("Cyberpunk2077.exe"));
}

test "exec rematch updates tracked pid from proton to specific profile" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();

    const proton_idx = try self.table.addProfile("proton");
    const game_idx = try self.table.addProfile("Cyberpunk2077.exe");
    self.table.proton_index = proton_idx;

    try self.known_pids.put(4242, proton_idx);
    self.profile_pid_counts[proton_idx] = 1;
    self.active_profile_idx = proton_idx;
    self.active_pid = 4242;

    self.matchAndActivateExec(4242, "Cyberpunk2077.exe");

    try std.testing.expectEqual(@as(?u8, game_idx), self.known_pids.get(4242));
    try std.testing.expectEqual(@as(u16, 0), self.profile_pid_counts[proton_idx]);
    try std.testing.expectEqual(@as(u16, 1), self.profile_pid_counts[game_idx]);
    try std.testing.expectEqual(@as(?u8, game_idx), self.active_profile_idx);
}

test "releaseTrackedPid starts grace when active profile drains" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();

    const proton_idx = try self.table.addProfile("proton");
    try self.known_pids.put(4242, proton_idx);
    self.profile_pid_counts[proton_idx] = 1;
    self.active_profile_idx = proton_idx;

    try std.testing.expectEqual(@as(?u8, proton_idx), self.releaseTrackedPid(4242, true, .exit));
    try std.testing.expect(self.deactivation_deadline != null);
    try std.testing.expectEqual(@as(u16, 0), self.profile_pid_counts[proton_idx]);
}

test "handleForkEvent queues child for deferred rematch" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();

    self.active_pid = 111;

    self.handleForkEvent(111, 222);

    try std.testing.expectEqual(@as(usize, 1), self.pending_rechecks.len);
    try std.testing.expectEqual(@as(u32, 222), self.pending_rechecks.constSlice()[0].pid);
    try std.testing.expectEqual(@as(?u32, 222), self.active_pid);
    try std.testing.expectEqual(@as(?u8, null), self.known_pids.get(222));
}

test "activateProfile replaces stale active profile instead of queueing" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();
    defer self.queued_indices.deinit(std.testing.allocator);

    const old_idx = try self.table.addProfile("OldGame.exe");
    const new_idx = try self.table.addProfile("NewGame.exe");
    self.active_profile_idx = old_idx;

    self.activateProfile(new_idx, 777);

    try std.testing.expectEqual(@as(?u8, new_idx), self.active_profile_idx);
    try std.testing.expectEqual(@as(usize, 0), self.queued_indices.items.len);
}

test "ensureActiveProfileGrace heals stale active profile state" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();

    const idx = try self.table.addProfile("StaleGame.exe");
    self.active_profile_idx = idx;

    self.ensureActiveProfileGrace();

    try std.testing.expect(self.deactivation_deadline != null);
}

test "reconcileTrackedPidScan drops reused pid that no longer matches" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();

    const idx = try self.table.addProfile("OblivionRemastered-Win64-Shipping.exe");
    try self.known_pids.put(5555, idx);
    self.profile_pid_counts[idx] = 1;
    self.active_profile_idx = idx;

    try std.testing.expect(!self.reconcileTrackedPidScan(5555, "bash"));
    try std.testing.expectEqual(@as(?u8, null), self.known_pids.get(5555));
    try std.testing.expectEqual(@as(u16, 0), self.profile_pid_counts[idx]);
    try std.testing.expect(self.deactivation_deadline != null);
}

test "reconcileTrackedPidScan rematches tracked proton pid to specific profile" {
    var map = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer map.deinit();

    var self = Self{
        .allocator = std.testing.allocator,
        .config = .{
            .config = .{},
            .mtime_ns = 0,
            .allocator = std.testing.allocator,
        },
        .table = ProfileTable.init(),
        .known_pids = map,
        .inhibitor = Inhibitor.init(std.testing.allocator),
        .profiles_dir = "",
        .event_loop = undefined,
        .oneshot = true,
    };
    defer self.table.deinit(std.testing.allocator);
    defer self.config.deinit();
    defer self.inhibitor.deinit();

    const proton_idx = try self.table.addProfile("proton");
    const game_idx = try self.table.addProfile("Cyberpunk2077.exe");
    self.table.proton_index = proton_idx;
    try self.known_pids.put(5555, proton_idx);
    self.profile_pid_counts[proton_idx] = 1;
    self.active_profile_idx = proton_idx;

    try std.testing.expect(self.reconcileTrackedPidScan(5555, "Cyberpunk2077.exe"));
    try std.testing.expectEqual(@as(?u8, game_idx), self.known_pids.get(5555));
    try std.testing.expectEqual(@as(u16, 0), self.profile_pid_counts[proton_idx]);
    try std.testing.expectEqual(@as(u16, 1), self.profile_pid_counts[game_idx]);
}
