//! AMD 3D V-Cache partition mode control via sysfs.
//!
//! Controls /sys/bus/platform/drivers/amd_x3d_vcache/AMDI0101:00/amd_x3d_mode
//! Valid values: "frequency", "cache"

const std = @import("std");
const log = std.log.scoped(.vcache);

const sysfs_path = "/sys/bus/platform/drivers/amd_x3d_vcache/AMDI0101:00/amd_x3d_mode";

/// Read the current V-Cache mode from sysfs.
/// Returns "frequency" or "cache", or null if unavailable.
pub fn read() ?[]const u8 {
    const file = std.fs.openFileAbsolute(sysfs_path, .{}) catch return null;
    defer file.close();

    var buf: [32]u8 = undefined;
    const len = file.readAll(&buf) catch return null;
    const raw = std.mem.trim(u8, buf[0..len], " \n\r\t");

    if (std.mem.eql(u8, raw, "cache")) return "cache";
    if (std.mem.eql(u8, raw, "frequency")) return "frequency";
    return null;
}

/// Write a raw sysfs value ("frequency" or "cache") to the V-Cache mode node.
pub fn write(value: []const u8) !void {
    const file = std.fs.openFileAbsolute(sysfs_path, .{ .mode = .write_only }) catch |err| {
        switch (err) {
            error.FileNotFound, error.NoDevice => {
                log.debug("V-Cache sysfs not found — no 3D V-Cache hardware", .{});
                return;
            },
            else => {
                log.err("failed to open V-Cache sysfs: {}", .{err});
                return err;
            },
        }
    };
    defer file.close();

    file.writeAll(value) catch |err| {
        log.err("failed to write V-Cache mode '{s}': {}", .{ value, err });
        return err;
    };

    log.info("V-Cache mode set to '{s}'", .{value});
}

test "vcache types compile" {
    _ = write;
    _ = read;
}
