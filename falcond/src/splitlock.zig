//! Kernel split-lock mitigation control via sysctl.
//!
//! Controls /proc/sys/kernel/split_lock_mitigate
//! Valid values: 0 (off / warn-only), 1 (on / misery mode)

const std = @import("std");
const otter_utils = @import("otter_utils");
const log = std.log.scoped(.splitlock);
inline fn io_global() std.Io {
    return otter_utils.io.get();
}

const sysctl_path = "/proc/sys/kernel/split_lock_mitigate";

/// Read the current split_lock_mitigate value.
/// Returns 0 or 1, or null if unavailable (missing sysctl / unsupported kernel).
pub fn read() ?u8 {
    const io = io_global();
    const file = std.Io.Dir.openFileAbsolute(io, sysctl_path, .{}) catch return null;
    defer file.close(io);

    var buf: [16]u8 = undefined;
    const len = file.readPositionalAll(io, &buf, 0) catch return null;
    const raw = std.mem.trim(u8, buf[0..len], " \n\r\t");

    if (std.mem.eql(u8, raw, "0")) return 0;
    if (std.mem.eql(u8, raw, "1")) return 1;
    return null;
}

/// Write a split_lock_mitigate value (0 or 1).
/// Missing sysctl is treated as a no-op (older / unsupported kernels).
pub fn write(value: u8) !void {
    const io = io_global();
    const file = std.Io.Dir.openFileAbsolute(io, sysctl_path, .{ .mode = .write_only }) catch |err| {
        switch (err) {
            error.FileNotFound, error.NoDevice => {
                log.debug("split_lock_mitigate sysctl not found — unsupported kernel", .{});
                return;
            },
            else => {
                log.err("failed to open split_lock_mitigate sysctl: {}", .{err});
                return err;
            },
        }
    };
    defer file.close(io);

    var buf: [1]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    file.writeStreamingAll(io, text) catch |err| {
        log.err("failed to write split_lock_mitigate={d}: {}", .{ value, err });
        return err;
    };

    log.info("split_lock_mitigate set to {d}", .{value});
}

test "splitlock types compile" {
    _ = write;
    _ = read;
}
