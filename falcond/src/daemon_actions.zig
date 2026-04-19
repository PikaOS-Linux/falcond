const std = @import("std");
const otter_utils = @import("otter_utils");
const otter_desktop = @import("otter_desktop");
const scanner = @import("scanner.zig");
const vcache = @import("vcache.zig");
const status = @import("status.zig");

const ScxMode = otter_desktop.scx_loader.ScxMode;
const ScxScheduler = otter_desktop.scx_loader.ScxScheduler;

const log = std.log.scoped(.daemon);
const posix = std.posix;

pub fn activateProfile(self: anytype, idx: u8, pid: u32) void {
    if (self.active_profile_idx) |active| {
        if (active == idx) {
            if (self.deactivation_deadline != null) {
                self.deactivation_deadline = null;
                log.info("deactivation cancelled — new pid={d} for '{s}'", .{ pid, self.table.names[idx].get() });
            }
            return;
        }

        if (idx == self.table.proton_index and active != self.table.proton_index) {
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
    log.info("activating profile '{s}' (scx={s}, mode={s}, perf={}, vcache={s}, inhibit={})", .{
        name,
        @tagName(act.scx_sched),
        @tagName(act.scx_sched_props),
        act.performance_mode,
        @tagName(act.vcache_mode),
        act.idle_inhibit,
    });

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

    if (self.inhibitor.isInhibited()) {
        self.inhibitor.uninhibit();
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
    );
}
