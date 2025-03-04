const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
const builtin = @import("builtin");
pub const std_options = std.Options{
    .log_level = .debug,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .default, .level = .debug },
    },
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

const config_path: []const u8 = "/etc/falcond/config.conf";
const system_conf_path: []const u8 = "/usr/share/falcond/system.conf";

fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackAlloc();
    return gpa_vtable.alloc(gpa_ptr, len, ptr_align, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackResize();
    return gpa_vtable.resize(gpa_ptr, buf, log2_buf_align, new_len, ret_addr);
}

fn remap(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackResize();
    return gpa_vtable.remap(gpa_ptr, buf, log2_buf_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, ret_addr: usize) void {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackDealloc();
    gpa_vtable.free(gpa_ptr, buf, log2_buf_align, ret_addr);
}

var gpa_vtable: *const std.mem.Allocator.VTable = undefined;
var gpa_ptr: *anyopaque = undefined;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub fn main() !void {
    std.log.info("Starting falcond...", .{});
    var allocator: std.mem.Allocator = undefined;
    var tracker = AllocTracker{};
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    allocator = gpa;
    defer if (is_debug) {
        const leaked = debug_allocator.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leaks detected!", .{});
        }
        std.log.info("Memory operations - allocs: {}, deallocs: {}, resizes: {}", .{
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

    try checkAndUpgradeConfig(allocator, config_path);

    var daemon = try Daemon.init(allocator, config_path, system_conf_path, oneshot);
    defer daemon.deinit();

    try daemon.run();
}

fn checkAndUpgradeConfig(allocator: std.mem.Allocator, conf_path: []const u8) !void {
    const file = std.fs.openFileAbsolute(conf_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, "system_processes = ")) |_| {
        std.log.info("Upgrading config file to new format", .{});
        file.close();
        try std.fs.deleteFileAbsolute(config_path);
    }
}
