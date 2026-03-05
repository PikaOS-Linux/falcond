const std = @import("std");
const Daemon = @import("daemon.zig");
const config_mod = @import("config.zig");
const builtin = @import("builtin");

pub const std_options = std.Options{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

const AllocTracker = struct {
    allocs: usize = 0,
    deallocs: usize = 0,
    resizes: usize = 0,

    pub fn trackAlloc(self: *@This()) void {
        self.allocs += 1;
    }

    pub fn trackDealloc(self: *@This()) void {
        self.deallocs += 1;
    }

    pub fn trackResize(self: *@This()) void {
        self.resizes += 1;
    }
};

var gpa_vtable: *const std.mem.Allocator.VTable = undefined;
var gpa_ptr: *anyopaque = undefined;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackAlloc();
    return gpa_vtable.alloc(gpa_ptr, len, ptr_align, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackResize();
    return gpa_vtable.resize(gpa_ptr, buf, log2_buf_align, new_len, ret_addr);
}

fn remap(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackResize();
    return gpa_vtable.remap(gpa_ptr, buf, log2_buf_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, ret_addr: usize) void {
    const t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackDealloc();
    gpa_vtable.free(gpa_ptr, buf, log2_buf_align, ret_addr);
}

pub fn main() !void {
    std.log.info("starting falcond...", .{});
    var allocator: std.mem.Allocator = undefined;
    var tracker = AllocTracker{};

    var release_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa, const is_debug = blk: {
        break :blk switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ release_gpa.allocator(), false },
        };
    };
    allocator = gpa;
    defer if (is_debug) {
        const leaked = debug_allocator.deinit();
        if (leaked == .leak) {
            std.log.err("memory leaks detected!", .{});
        }
        std.log.info("memory operations - allocs: {}, deallocs: {}, resizes: {}", .{
            tracker.allocs,
            tracker.deallocs,
            tracker.resizes,
        });
    };

    if (is_debug) {
        gpa_vtable = gpa.vtable;
        gpa_ptr = gpa.ptr;
        allocator = std.mem.Allocator{
            .ptr = &tracker,
            .vtable = &std.mem.Allocator.VTable{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const oneshot = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--oneshot")) break true;
    } else false;

    // Block SIGTERM + SIGHUP so they arrive via signalfd instead of killing the process
    {
        const linux = std.os.linux;
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, linux.SIG.TERM);
        linux.sigaddset(&mask, linux.SIG.HUP);
        linux.sigaddset(&mask, linux.SIG.INT);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    }

    var daemon = try Daemon.init(allocator, config_mod.default_config_path, oneshot);
    defer daemon.deinit();

    try daemon.run();
}

test {
    _ = @import("config.zig");
    _ = @import("profiles.zig");
    _ = @import("scanner.zig");
    _ = @import("matcher.zig");
    _ = @import("vcache.zig");
    _ = @import("status.zig");
    _ = @import("inhibitor.zig");
    _ = @import("event_loop.zig");
}
