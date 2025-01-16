const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;

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

fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackAlloc();
    return gpa_vtable.alloc(gpa_ptr, len, ptr_align, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ret_addr: usize) bool {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackResize();
    return gpa_vtable.resize(gpa_ptr, buf, log2_buf_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
    var t: *AllocTracker = @ptrCast(@alignCast(ctx));
    t.trackDealloc();
    gpa_vtable.free(gpa_ptr, buf, log2_buf_align, ret_addr);
}

var gpa_vtable: *const std.mem.Allocator.VTable = undefined;
var gpa_ptr: *anyopaque = undefined;
pub fn main() !void {
    std.log.info("Starting falcond...", .{});

    var tracker = AllocTracker{};
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .verbose_log = false,
        .enable_memory_limit = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leaks detected!", .{});
        }
        std.log.info("Memory operations - allocs: {}, deallocs: {}, resizes: {}", .{
            tracker.allocs,
            tracker.deallocs,
            tracker.resizes,
        });
    }

    gpa_vtable = gpa.allocator().vtable;
    gpa_ptr = gpa.allocator().ptr;
    const allocator = std.mem.Allocator{
        .ptr = &tracker,
        .vtable = &std.mem.Allocator.VTable{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };

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
