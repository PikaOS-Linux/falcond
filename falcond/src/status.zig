const std = @import("std");
const otter_utils = @import("otter_utils");
const ProfileTable = @import("profiles.zig").ProfileTable;
const otter_desktop = @import("otter_desktop");
const PowerProfiles = otter_desktop.PowerProfiles;
const ScxLoader = otter_desktop.scx_loader.ScxLoader;
const Config = @import("config.zig").Config;
const Inhibitor = @import("inhibitor.zig");
const vcache = @import("vcache.zig");
const build_options = @import("build_options");
const log = std.log.scoped(.status);
inline fn io_global() std.Io { return otter_utils.io.get(); }

// ── Paths (configurable via build options, zero runtime cost) ────────────────

const status_file: []const u8 = build_options.status_file;
const status_dir: []const u8 = std.fs.path.dirname(status_file) orelse "/var/lib/falcond";
const tmp_status_file: []const u8 = build_options.tmp_status_file;

// ── Public API ───────────────────────────────────────────────────────────────

pub fn update(
    config: Config,
    table: *const ProfileTable,
    active_profile_idx: ?u8,
    queued_indices: []const u8,
    power_profiles: ?*PowerProfiles,
    scx_loader: ?*ScxLoader,
    restore_sched: ?[]const u8,
    restore_mode: ?[]const u8,
    restore_power_profile: ?[:0]const u8,
    inhibitor: *const Inhibitor,
) void {
    writeStatusFile(
        config,
        table,
        active_profile_idx,
        queued_indices,
        power_profiles,
        scx_loader,
        restore_sched,
        restore_mode,
        restore_power_profile,
        inhibitor,
    ) catch |err| {
        log.err("failed to write status file: {}", .{err});
    };
}

// ── Internal ─────────────────────────────────────────────────────────────────

fn writeStatusFile(
    config: Config,
    table: *const ProfileTable,
    active_profile_idx: ?u8,
    queued_indices: []const u8,
    power_profiles: ?*PowerProfiles,
    scx_loader: ?*ScxLoader,
    restore_sched: ?[]const u8,
    restore_mode: ?[]const u8,
    restore_power_profile: ?[:0]const u8,
    inhibitor: *const Inhibitor,
) !void {
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(std.heap.page_allocator);
    var allocating_writer: std.Io.Writer.Allocating = .fromArrayList(std.heap.page_allocator, &content_buf);
    defer content_buf = allocating_writer.toArrayList();
    const w = &allocating_writer.writer;

    // ── FEATURES ────────────────────────────────────────────────────────
    try w.writeAll("FEATURES:\n");
    try w.print("  Performance Mode: {s}\n", .{
        if (power_profiles != null) "Available" else "Unavailable",
    });
    try w.writeAll("\n");

    // ── CONFIG ──────────────────────────────────────────────────────────
    try w.writeAll("CONFIG:\n");
    try w.print("  Profile Mode: {s}\n", .{@tagName(config.profile_mode)});
    try w.print("  Global VCache Mode: {s}\n", .{@tagName(config.vcache_mode)});
    try w.print("  Global SCX Scheduler: {s}\n", .{@tagName(config.scx_sched)});
    try w.writeAll("\n");

    // ── AVAILABLE_SCX_SCHEDULERS ─────────────────────────────────────────
    try w.writeAll("AVAILABLE_SCX_SCHEDULERS:\n");
    if (scx_loader) |scx| {
        const supported = scx.getSupportedSchedulers();
        if (supported.len > 0) {
            for (supported) |sched| {
                try w.print("  - {s}\n", .{sched.toScxName()});
            }
        } else {
            try w.writeAll("  (None or scx_loader unavailable)\n");
        }
    } else {
        try w.writeAll("  (None or scx_loader unavailable)\n");
    }
    try w.writeAll("\n");

    // ── LOADED_PROFILES ──────────────────────────────────────────────────
    try w.print("LOADED_PROFILES: {d}\n\n", .{table.count});

    // ── ACTIVE_PROFILE ───────────────────────────────────────────────────
    try w.writeAll("ACTIVE_PROFILE: ");
    if (active_profile_idx) |idx| {
        try w.print("{s}\n", .{table.names[idx].get()});
    } else {
        try w.writeAll("None\n");
    }
    try w.writeAll("\n");

    // ── QUEUED_PROFILES ──────────────────────────────────────────────────
    try w.writeAll("QUEUED_PROFILES:\n");
    if (queued_indices.len > 0) {
        for (queued_indices) |idx| {
            try w.print("  - {s}\n", .{table.names[idx].get()});
        }
    } else {
        try w.writeAll("  (None)\n");
    }
    try w.writeAll("\n");

    // ── RESTORE_STATE (only when a profile is active) ────────────────────
    if (active_profile_idx != null) {
        try w.writeAll("RESTORE_STATE:\n");
        if (restore_sched) |s| {
            const mode_str = restore_mode orelse "default";
            try w.print("  SCX Scheduler: {s} (Mode: {s})\n", .{ s, mode_str });
        } else {
            try w.writeAll("  SCX Scheduler: (None)\n");
        }
        try w.print("  Power Profile: {s}\n", .{restore_power_profile orelse "balanced"});
        try w.writeAll("\n");
    }

    // ── CURRENT_STATUS (only when a profile is active) ───────────────────
    if (active_profile_idx != null) {
        try w.writeAll("CURRENT_STATUS:\n");

        // Performance Mode
        if (power_profiles) |pp| {
            const active = pp.getActiveProfile() orelse "unknown";
            if (std.mem.eql(u8, active, "performance")) {
                try w.writeAll("  Performance Mode: Active\n");
            } else {
                try w.writeAll("  Performance Mode: Inactive\n");
            }
        } else {
            try w.writeAll("  Performance Mode: Disabled/Unavailable\n");
        }

        // VCache Mode
        if (vcache.read()) |mode| {
            try w.print("  VCache Mode: {s}\n", .{mode});
        } else {
            try w.writeAll("  VCache Mode: N/A\n");
        }

        // SCX Scheduler
        if (scx_loader) |scx| {
            if (scx.getCurrentScheduler()) |sched| {
                const name = sched.toScxName();
                if (name.len > 0) {
                    try w.print("  SCX Scheduler: {s}\n", .{name});
                } else {
                    try w.writeAll("  SCX Scheduler: (None)\n");
                }
            } else {
                try w.writeAll("  SCX Scheduler: (None)\n");
            }
        } else {
            try w.writeAll("  SCX Scheduler: (None)\n");
        }

        // Screensaver Inhibit
        try w.print("  Screensaver Inhibit: {s}\n", .{
            if (inhibitor.isInhibited()) "Active" else "Inactive",
        });

        try w.writeAll("\n");
    }

    const content = content_buf.items;

    // Write to permanent status file
    std.Io.Dir.cwd().createDirPath(io_global(), status_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    {
        const file = try std.Io.Dir.createFileAbsolute(io_global(), status_file, .{});
        defer file.close(io_global());
        try file.writeStreamingAll(io_global(), content);
    }

    // Write to tmp status file
    {
        const tmp_file = try std.Io.Dir.createFileAbsolute(io_global(), tmp_status_file, .{});
        defer tmp_file.close(io_global());
        try tmp_file.writeStreamingAll(io_global(), content);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "status types compile" {
    _ = update;
}
