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
    return try parser.parse();
}

pub fn loadConfDir(comptime T: type, allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(T) {
    var result = std.ArrayList(T).init(allocator);
    errdefer result.deinit();

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".conf")) {
            const path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
            defer allocator.free(path);

            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();

            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(content);

            var parser = Parser(T).init(allocator, content);
            const parsed = try parser.parse();
            try result.append(parsed);
        }
    }

    return result;
}
