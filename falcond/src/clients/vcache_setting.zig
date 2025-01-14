const std = @import("std");
const fs = std.fs;

pub const VCacheMode = enum {
    cache,
    freq,
    none,
};

const vcache_path = "/sys/bus/platform/drivers/amd_x3d_vcache/AMDI0101:00/amd_x3d_mode";

var previous_mode: ?[]const u8 = null;
var previous_mode_buffer: [10]u8 = undefined;

pub fn applyVCacheMode(vcache_mode: VCacheMode) void {
    const file = fs.openFileAbsolute(vcache_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("AMD 3D vcache support not detected", .{});
            return;
        },
        else => {
            std.log.err("Failed to open vcache file: {}", .{err});
            return;
        },
    };
    defer file.close();

    if (vcache_mode == .none) {
        if (previous_mode) |mode| {
            std.log.info("Restoring previous vcache mode: {s}", .{mode});
            file.writeAll(mode) catch |err| {
                std.log.err("Failed to restore previous vcache mode: {}", .{err});
            };
            previous_mode = null;
        }
        return;
    }

    const bytes_read = file.readAll(previous_mode_buffer[0..]) catch |err| {
        std.log.err("Failed to read current vcache mode: {}", .{err});
        return;
    };
    if (bytes_read > 0) {
        previous_mode = previous_mode_buffer[0..bytes_read];
    }

    file.seekTo(0) catch |err| {
        std.log.err("Failed to seek vcache file: {}", .{err});
        return;
    };

    const mode_str = switch (vcache_mode) {
        .freq => "frequency",
        .cache => "cache",
        .none => unreachable,
    };

    std.log.info("Setting vcache mode to: {s}", .{mode_str});
    file.writeAll(mode_str) catch |err| {
        std.log.err("Failed to write vcache mode: {}", .{err});
    };
}
