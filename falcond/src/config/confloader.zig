const std = @import("std");
const Parser = @import("parser.zig").Parser;

pub fn loadConf(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const file = try std.fs.openFileAbsolute(path, .{
        .mode = .read_only,
        .lock = .none,
        .lock_nonblocking = false,
    });
    defer file.close();

    const size = try file.getEndPos();
    if (size > std.math.maxInt(u32)) return error.FileTooLarge;

    var stack_buffer: [4096]u8 = undefined;
    const buffer = if (size <= stack_buffer.len) stack_buffer[0..size] else try allocator.alloc(u8, size);
    defer if (size > stack_buffer.len) allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != size) return error.UnexpectedEOF;

    var parser = Parser(T).init(allocator, buffer);
    return parser.parse() catch |err| {
        std.log.err("Failed to parse config file '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
}

pub fn loadConfDir(comptime T: type, allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayListUnmanaged(T) {
    var result = std.ArrayListUnmanaged(T){};
    errdefer result.deinit(allocator);

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".conf")) {
            const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(path);

            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();

            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(content);

            var parser = Parser(T).init(allocator, content);
            const parsed = parser.parse() catch |err| {
                std.log.err("Failed to parse config file '{s}': {s}", .{ path, @errorName(err) });
                return err;
            };
            try result.append(allocator, parsed);
        }
    }

    return result;
}
