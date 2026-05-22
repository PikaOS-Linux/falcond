const std = @import("std");

pub fn nowNs() i128 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) {
        return 0;
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
