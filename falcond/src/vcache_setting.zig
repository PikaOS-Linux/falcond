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

pub fn applyVCacheMode(vcache_mode: VCacheMode) !void {
    const file = fs.openFileAbsolute(vcache_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    if (vcache_mode == .none) {
        if (previous_mode) |mode| {
            try file.writeAll(mode);
            previous_mode = null;
        }
        return;
    }

    const bytes_read = try file.readAll(previous_mode_buffer[0..]);
    if (bytes_read > 0) {
        previous_mode = previous_mode_buffer[0..bytes_read];
    }

    try file.seekTo(0);

    try file.writeAll(switch (vcache_mode) {
        .freq => "frequency",
        .cache => "cache",
        .none => unreachable,
    });
}
