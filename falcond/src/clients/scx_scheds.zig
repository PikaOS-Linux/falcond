const std = @import("std");
const dbus = @import("./dbus.zig");

pub const ScxError = dbus.DBusError;

pub const ScxScheduler = enum {
    bpfland,
    central,
    flash,
    flatcg,
    lavd,
    layered,
    nest,
    pair,
    qmap,
    rlfifo,
    rustland,
    rusty,
    sdt,
    simple,
    userland,
    vder,
    none,

    pub fn toScxName(self: ScxScheduler) []const u8 {
        return switch (self) {
            .none => "",
            inline else => |tag| "scx_" ++ @tagName(tag),
        };
    }

    pub fn fromString(str: []const u8) ScxError!ScxScheduler {
        if (std.mem.eql(u8, str, "none")) return .none;
        if (std.mem.eql(u8, str, "scx_none")) return .none;
        if (std.mem.eql(u8, str, "unknown")) return .none;
        if (std.mem.eql(u8, str, "scx_bpfland")) return .bpfland;
        if (std.mem.eql(u8, str, "scx_central")) return .central;
        if (std.mem.eql(u8, str, "scx_flash")) return .flash;
        if (std.mem.eql(u8, str, "scx_flatcg")) return .flatcg;
        if (std.mem.eql(u8, str, "scx_lavd")) return .lavd;
        if (std.mem.eql(u8, str, "scx_layered")) return .layered;
        if (std.mem.eql(u8, str, "scx_nest")) return .nest;
        if (std.mem.eql(u8, str, "scx_pair")) return .pair;
        if (std.mem.eql(u8, str, "scx_qmap")) return .qmap;
        if (std.mem.eql(u8, str, "scx_rlfifo")) return .rlfifo;
        if (std.mem.eql(u8, str, "scx_rustland")) return .rustland;
        if (std.mem.eql(u8, str, "scx_rusty")) return .rusty;
        if (std.mem.eql(u8, str, "scx_sdt")) return .sdt;
        if (std.mem.eql(u8, str, "scx_simple")) return .simple;
        if (std.mem.eql(u8, str, "scx_userland")) return .userland;
        if (std.mem.eql(u8, str, "scx_vder")) return .vder;

        return error.InvalidValue;
    }
};

pub const ScxSchedModes = enum {
    default,
    power,
    gaming,
    latency,
    server,
};

const State = struct {
    scheduler: ?ScxScheduler = null,
    mode: ?ScxSchedModes = null,
};

var previous_state = State{};
var supported_schedulers: []ScxScheduler = &[_]ScxScheduler{};
var allocator: std.mem.Allocator = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    allocator = alloc;
    std.log.info("Initializing scheduler state", .{});

    const sched_list = try getSupportedSchedulers(alloc);
    defer alloc.free(sched_list);

    std.log.info("Supported schedulers:", .{});
    if (sched_list.len > 0) {
        for (sched_list) |sched| {
            std.log.info("  - {s}", .{sched.toScxName()});
        }
        supported_schedulers = try alloc.dupe(ScxScheduler, sched_list);
    } else {
        supported_schedulers = &[_]ScxScheduler{};
    }
}

pub fn deinit() void {
    if (supported_schedulers.len > 0) {
        allocator.free(supported_schedulers);
    }
}

const SCX_NAME = "org.scx.Loader";
const SCX_PATH = "/org/scx/Loader";
const SCX_IFACE = "org.scx.Loader";

fn modeToInt(mode: ScxSchedModes) u32 {
    return switch (mode) {
        .default => 0,
        .power => 1,
        .gaming => 2,
        .latency => 3,
        .server => 4,
    };
}

fn intToMode(value: u32) ScxError!ScxSchedModes {
    return switch (value) {
        0 => .default,
        1 => .power,
        2 => .gaming,
        3 => .latency,
        4 => .server,
        else => error.InvalidValue,
    };
}

pub fn getCurrentScheduler(alloc: std.mem.Allocator) !?ScxScheduler {
    var dbus_conn = dbus.DBus.init(alloc, SCX_NAME, SCX_PATH, SCX_IFACE);

    const current = try dbus_conn.getProperty("CurrentScheduler");
    defer alloc.free(current);

    if (current.len == 0) return null;
    return try ScxScheduler.fromString(current);
}

pub fn getCurrentMode(alloc: std.mem.Allocator) !ScxSchedModes {
    var dbus_conn = dbus.DBus.init(alloc, SCX_NAME, SCX_PATH, SCX_IFACE);

    const mode_str = try dbus_conn.getProperty("SchedulerMode");
    defer alloc.free(mode_str);

    if (mode_str.len == 0) return .default;

    const mode = try std.fmt.parseInt(u32, mode_str, 10);
    return intToMode(mode);
}

pub fn getSupportedSchedulers(alloc: std.mem.Allocator) ![]ScxScheduler {
    var dbus_conn = dbus.DBus.init(alloc, SCX_NAME, SCX_PATH, SCX_IFACE);

    const schedulers = try dbus_conn.getPropertyArray("SupportedSchedulers");
    defer {
        for (schedulers) |s| {
            alloc.free(s);
        }
        alloc.free(schedulers);
    }

    var result = try std.ArrayList(ScxScheduler).initCapacity(alloc, schedulers.len);
    errdefer result.deinit();

    for (schedulers) |s| {
        const scheduler = try ScxScheduler.fromString(s);
        try result.append(scheduler);
    }

    return result.toOwnedSlice();
}

pub fn storePreviousState(alloc: std.mem.Allocator) !void {
    std.log.info("Storing current scheduler state", .{});
    if (try getCurrentScheduler(alloc)) |scheduler| {
        if (scheduler == .none) {
            std.log.info("Current scheduler is none", .{});
            previous_state.scheduler = null;
            previous_state.mode = null;
        } else {
            std.log.info("Storing current scheduler: {s}", .{scheduler.toScxName()});
            previous_state.scheduler = scheduler;
            previous_state.mode = try getCurrentMode(alloc);
        }
    } else {
        std.log.info("No current scheduler", .{});
        previous_state.scheduler = null;
        previous_state.mode = null;
    }
}

fn isSchedulerSupported(scheduler: ScxScheduler) bool {
    if (scheduler == .none) return true;

    for (supported_schedulers) |s| {
        if (s == scheduler) return true;
    }
    return false;
}

pub fn activateScheduler(alloc: std.mem.Allocator, scheduler: ScxScheduler, mode: ?ScxSchedModes) ScxError!void {
    var dbus_conn = dbus.DBus.init(alloc, SCX_NAME, SCX_PATH, SCX_IFACE);

    const mode_str = try std.fmt.allocPrint(alloc, "{d}", .{modeToInt(mode orelse .default)});
    defer alloc.free(mode_str);

    const args = [_][]const u8{
        "su",
        scheduler.toScxName(),
        mode_str,
    };

    try dbus_conn.callMethod("SwitchScheduler", &args);
}

pub fn applyScheduler(alloc: std.mem.Allocator, scheduler: ScxScheduler, mode: ?ScxSchedModes) void {
    storePreviousState(alloc) catch |err| {
        std.log.err("Failed to store previous state: {}", .{err});
    };

    if (scheduler == .none) {
        std.log.info("No scheduler to apply for this profile", .{});
        deactivateScheduler(alloc) catch |err| {
            std.log.err("Failed to deactivate scheduler: {}", .{err});
        };
        return;
    }

    if (!isSchedulerSupported(scheduler)) {
        std.log.info("Scheduler {s} not supported by system", .{scheduler.toScxName()});
        return;
    }

    if (mode) |m| {
        std.log.info("Applying scheduler {s} with mode {s}", .{ scheduler.toScxName(), @tagName(m) });
    } else {
        std.log.info("Applying scheduler {s} with default mode", .{scheduler.toScxName()});
    }

    activateScheduler(alloc, scheduler, mode orelse .default) catch |err| {
        std.log.err("Failed to activate scheduler {s}: {}", .{ scheduler.toScxName(), err });
    };
}

pub fn deactivateScheduler(alloc: std.mem.Allocator) ScxError!void {
    var dbus_conn = dbus.DBus.init(alloc, SCX_NAME, SCX_PATH, SCX_IFACE);
    try dbus_conn.callMethod("StopScheduler", &[_][]const u8{});
}

pub fn restorePreviousState(alloc: std.mem.Allocator) void {
    if (previous_state.scheduler) |scheduler| {
        if (previous_state.mode) |mode| {
            std.log.info("Restoring previous scheduler {s} with mode {s}", .{ scheduler.toScxName(), @tagName(mode) });
            activateScheduler(alloc, scheduler, mode) catch |err| {
                std.log.err("Failed to restore previous scheduler: {}", .{err});
            };
        }
        previous_state.scheduler = null;
        previous_state.mode = null;
    } else {
        std.log.info("Previous state was none, stopping scheduler", .{});
        deactivateScheduler(alloc) catch |err| {
            std.log.err("Failed to stop scheduler: {}", .{err});
        };
    }
}
