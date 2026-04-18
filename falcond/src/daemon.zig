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
const status = @import("status.zig");
const vcache = @import("vcache.zig");
const EventLoop = @import("event_loop.zig");

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
/// Grace period for deactivation. Allows time for Wine/Proton child processes
/// to be discovered via fork events or the next /proc scan. Fixed at 3 seconds
/// — long enough for fork tracking + one fast-poll cycle, short enough that
/// lingering game profiles don't annoy the user.
const deactivation_grace_ns: i128 = 3000 * std.time.ns_per_ms;
/// Minimum interval between inotify-triggered reloads. Prevents feedback loops
/// caused by watch re-registration (IN_IGNORED events) and external tools
/// probing watched directories (e.g. falcond-gui's write permission test).
const reload_debounce_ns: i128 = 1000 * std.time.ns_per_ms;

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
        vcache.write(val) catch |err| {
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

    self.updateStatus();
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.active_profile_idx) |idx| {
        self.deactivateProfile(idx);
    }

    // Write final status before tearing down D-Bus connections
    self.updateStatus();

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

    // Wire up fork tracking now that self has a stable address
    self.event_loop.tracked_pids = &self.known_pids;
    self.event_loop.profile_pid_counts = &self.profile_pid_counts;

    // Initial /proc scan to catch processes already running before daemon started
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
                    self.updateStatus();
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
                        self.updateStatus(); // flush deactivated state for external watchers
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
                    // Only run full /proc scan at the configured interval, not during fast-poll
                    const now = nowNs();
                    const interval_ns: i128 = @as(i128, self.config.config.poll_interval_ms) * std.time.ns_per_ms;
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

        self.checkDeactivationGrace();

        if (self.status_dirty) {
            self.updateStatus();
            self.status_dirty = false;
        }
    }
}

fn handleForkEvent(self: *Self, parent: u32, child: u32) void {
    // Child already tracked by event_loop — cancel any pending deactivation
    self.deactivation_deadline = null;
    // Keep active_pid/active_uid pointing at a live process so stop scripts
    // run as the correct user after the original parent exits.
    if (self.active_pid != null and self.active_pid.? == parent) {
        self.active_pid = child;
        self.active_uid = scanner.findUserForProcess(child);
    }
}

fn handleExecEvent(self: *Self, pid: u32) void {
    if (pid <= 2) return;
    if (self.known_pids.contains(pid)) return;

    // Fast path: read /proc/pid/comm (kernel-cached, ~0 cost) and skip
    // processes that can't possibly match any profile. Avoids the expensive
    // cmdline read + arena alloc for the vast majority of system processes.
    const comm_buf = scanner.getProcessComm(pid) orelse return;
    const comm = std.mem.sliceTo(&comm_buf, 0);
    if (!self.couldMatch(comm)) return;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const name = scanner.getProcessName(alloc, pid) orelse return;

    // Wine/Proton preloaders update cmdline after exec — queue for deferred recheck
    if (isWinePreloader(name)) {
        self.queueRecheck(pid, max_rechecks);
        return;
    }

    self.matchAndActivate(pid, name);
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

        // Entry expired — consume it (don't write back)

        if (self.known_pids.contains(entry.pid)) continue;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const name = scanner.getProcessName(alloc, entry.pid) orelse continue;

        // Still a preloader — re-queue if retries remain
        if (isWinePreloader(name)) {
            if (entry.retries > 0) {
                self.queueRecheck(entry.pid, entry.retries - 1);
            } else {
                log.debug("recheck exhausted pid={d}, still '{s}'", .{ entry.pid, name });
            }
            continue;
        }

        // Drop system .exe processes immediately
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
        log.info("matched pid={d} name='{s}' profile='{s}'", .{
            pid, name, self.table.names[result.profile_idx].get(),
        });
        self.known_pids.put(pid, result.profile_idx) catch {};
        self.profile_pid_counts[result.profile_idx] += 1;
        self.status_dirty = true;
        self.activateProfile(result.profile_idx, pid);
    }
}

fn handleExitEvent(self: *Self, pid: u32) void {
    const profile_idx = self.known_pids.get(pid) orelse return;
    log.debug("exit pid={d} profile='{s}'", .{ pid, self.table.names[profile_idx].get() });
    _ = self.known_pids.remove(pid);
    self.profile_pid_counts[profile_idx] -= 1;
    self.status_dirty = true;

    if (self.active_profile_idx) |active_idx| {
        if (active_idx == profile_idx) {
            if (!self.hasAnyPidForProfile(profile_idx)) {
                // Start grace period — Wine/Proton processes re-exec frequently
                self.deactivation_deadline = nowNs() + deactivation_grace_ns;
                log.info("last pid for '{s}' exited, grace period started", .{self.table.names[profile_idx].get()});
            }
        }
    }
}

fn reload(self: *Self) !void {
    // Allocate new state before destroying old — avoids dangling on failure
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

    // New state ready — safe to tear down old state
    if (self.active_profile_idx) |idx| {
        self.deactivateProfile(idx);
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

    // Track the best profile to activate after the scan — specific profiles
    // take priority over the generic proton fallback.
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

        if (self.known_pids.contains(pid)) {
            alive.put(pid, {}) catch {};
            continue;
        }

        const comm_buf = scanner.getProcessComm(pid) orelse continue;
        const comm = std.mem.sliceTo(&comm_buf, 0);
        if (!self.couldMatch(comm)) continue;

        if (self.isSystemProcess(name)) continue;

        const result = matcher_mod.matchProcess(
            &self.table,
            self.config.config,
            pid,
            name,
        );

        if (result.matched()) {
            self.known_pids.put(pid, result.profile_idx) catch {};
            self.profile_pid_counts[result.profile_idx] += 1;
            alive.put(pid, {}) catch {};

            // If no active profile, pick the best candidate to activate after scan
            if (self.active_profile_idx == null) {
                if (shouldPreferCandidate(&self.table, best_idx, best_pid, best_is_proton, result, pid, preferred_idx)) {
                    best_idx = result.profile_idx;
                    best_pid = pid;
                    best_is_proton = result.is_proton;
                }
            } else {
                self.activateProfile(result.profile_idx, pid);
            }
        }
    }

    // Activate deferred best match
    if (self.active_profile_idx == null) {
        if (best_idx) |idx| {
            self.activateProfile(idx, best_pid);
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
            const profile_idx = self.known_pids.get(pid) orelse continue;
            _ = self.known_pids.remove(pid);
            self.profile_pid_counts[profile_idx] -= 1;

            if (self.active_profile_idx) |active_idx| {
                if (active_idx == profile_idx and !self.hasAnyPidForProfile(profile_idx)) {
                    // Use same grace period as handleExitEvent — Wine/Proton
                    // children may not have been discovered yet.
                    if (self.deactivation_deadline == null) {
                        self.deactivation_deadline = nowNs() + deactivation_grace_ns;
                        log.info("last pid for '{s}' gone from /proc, grace period started", .{self.table.names[profile_idx].get()});
                    }
                }
            }
        }
    }
}

fn activateProfile(self: *Self, idx: u8, pid: u32) void {
    if (self.active_profile_idx) |active| {
        if (active == idx) {
            // Same profile — cancel any pending deactivation
            if (self.deactivation_deadline != null) {
                self.deactivation_deadline = null;
                log.info("deactivation cancelled — new pid={d} for '{s}'", .{ pid, self.table.names[idx].get() });
            }
            return;
        }

        if (shouldIgnoreProtonFallback(active, idx, self.table.proton_index)) {
            log.info("ignoring proton fallback while specific profile '{s}' is active", .{
                self.table.names[active].get(),
            });
            return;
        }

        // Specific profiles always supersede the generic proton fallback
        const new_beats_active = (active == self.table.proton_index and idx != self.table.proton_index);

        if (self.deactivation_deadline != null or new_beats_active) {
            self.deactivation_deadline = null;
            self.deactivateProfile(active);
            // Fall through to activate the new profile below
        } else {
            if (shouldIgnoreProtonFallback(active, idx, self.table.proton_index)) {
                log.info("ignoring queued proton fallback while specific profile '{s}' remains active", .{
                    self.table.names[active].get(),
                });
                return;
            }

            // Current profile still has PIDs — queue the new one if not already queued
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

    self.active_profile_idx = idx;
    self.active_pid = pid;

    // Process may exit before deactivation, so cache the UID now
    if (pid != 0) {
        self.active_uid = scanner.findUserForProcess(pid);
    }

    const act = &self.table.activation[idx];
    const name = self.table.names[idx].get();
    log.info("activating profile '{s}' (scx={s}, mode={s}, perf={}, vcache={s}, inhibit={})", .{
        name,
        @tagName(act.scx_sched),
        @tagName(act.scx_sched_props),
        act.performance_mode,
        @tagName(act.vcache_mode),
        act.idle_inhibit,
    });

    // Snapshot current state so we can restore on deactivation
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

    if (act.idle_inhibit) {
        self.inhibitor.inhibit("falcond", "Game profile active", pid);
    }

    if (!act.start_script.isEmpty()) {
        self.runScript(act.start_script.get());
    }

    self.status_dirty = true;
}

fn deactivateProfile(self: *Self, idx: u8) void {
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

    if (self.inhibitor.isInhibited()) {
        self.inhibitor.uninhibit();
    }

    if (!act.stop_script.isEmpty()) {
        self.runScript(act.stop_script.get());
    }

    self.active_profile_idx = null;
    self.active_pid = null;
    self.active_uid = null;
    self.status_dirty = true;
}

/// Run a profile script, dropping to the process owner's session when running as root.
fn runScript(self: *Self, script: []const u8) void {
    if (posix.system.geteuid() == 0) {
        const uid = self.active_uid orelse {
            log.warn("no saved uid, running script as root", .{});
            otter_utils.process.spawnCommand(otter_utils.io.get(), script);
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const uid_str = std.fmt.allocPrint(alloc, "#{d}", .{uid}) catch return;
        const dbus_env = std.fmt.allocPrint(alloc, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus", .{uid}) catch return;

        // Use explicit argv so script content can't escape the sh -c argument
        const argv = [_][]const u8{
            "sudo",    "-u",     uid_str,
            "env",     dbus_env, "DISPLAY=:0",
            "/bin/sh", "-c",     script,
        };

        otter_utils.process.spawnArgv(otter_utils.io.get(), &argv);
    } else {
        otter_utils.process.spawnCommand(otter_utils.io.get(), script);
    }
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

/// Quick check whether a /proc/pid/comm value could ever match a profile.
/// Returns true for: wine/proton preloaders, .exe names, and names present
/// in the profile table. Returns false for everything else (bash, foot, ls …),
/// letting handleExecEvent skip the expensive cmdline read.
///
/// NOTE: /proc/pid/comm is truncated to 15 chars by the kernel, so we use
/// prefix checks for wine and substring checks for .exe.
fn couldMatch(self: *Self, comm: []const u8) bool {
    if (comm.len == 0) return false;
    // Wine/Proton preloaders — prefix match because comm truncates
    // "wine64-preloader" (16 chars) to "wine64-preloade"
    if (std.mem.startsWith(u8, comm, "wine")) return true;
    // .exe anywhere in comm — handles truncation where suffix may shift
    // e.g. "MyLongGame.exe" truncated still contains ".exe"
    if (std.ascii.indexOfIgnoreCase(comm, ".exe") != null) return true;
    // Comm is 15 chars max — if it's exactly 15, the real name may be
    // longer and could end in .exe that got truncated away
    if (comm.len >= 15) return true;
    // Direct profile name match (hash map then case-insensitive)
    if (self.table.name_map.get(comm) != null) return true;
    if (self.table.findByName(comm) != null) return true;
    return false;
}

fn computeTimeout(self: *Self) u32 {
    // Poll faster when grace period or deferred rechecks are pending
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

    // Check if new PIDs appeared during grace period
    if (self.hasAnyPidForProfile(idx)) {
        self.deactivation_deadline = null;
        log.info("profile '{s}' kept alive by remaining processes", .{self.table.names[idx].get()});
        return;
    }

    // Pending rechecks may resolve to the game (wine preloader → game exe) — extend grace
    if (self.pending_rechecks.len > 0) {
        self.deactivation_deadline = nowNs() + deactivation_grace_ns;
        log.debug("extending grace — {d} pending rechecks", .{self.pending_rechecks.len});
        return;
    }

    self.deactivation_deadline = null;
    log.info("grace period expired, deactivating profile '{s}'", .{self.table.names[idx].get()});
    self.deactivateProfile(idx);

    // Promote next queued profile
    if (self.queued_indices.items.len > 0) {
        const next = self.queued_indices.orderedRemove(0);
        if (self.findPidForProfile(next)) |next_pid| {
            self.activateProfile(next, next_pid);
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

fn updateStatus(self: *Self) void {
    status.update(
        self.config.config,
        &self.table,
        self.active_profile_idx,
        self.queued_indices.items,
        if (self.power_profiles) |*pp| pp else null,
        if (self.scx_loader) |*scx| scx else null,
        self.restore_sched,
        self.restore_mode,
        self.restore_power_profile,
        &self.inhibitor,
    );
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
