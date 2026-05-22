const std = @import("std");

pub const Region = struct {
    name: []const u8,
    capacity: u64,
};

pub const ProtectState = enum {
    inactive,
    active,
};

pub fn parseCapacity(allocator: std.mem.Allocator, content: []const u8) ![]Region {
    var regions: std.ArrayList(Region) = .empty;
    errdefer {
        for (regions.items) |region| allocator.free(region.name);
        regions.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        const capacity_text = fields.next() orelse continue;
        if (fields.next() != null) continue;

        const capacity = std.fmt.parseUnsigned(u64, capacity_text, 10) catch return error.InvalidCapacity;
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        try regions.append(allocator, .{ .name = name_copy, .capacity = capacity });
    }

    return try regions.toOwnedSlice(allocator);
}

pub fn freeRegions(allocator: std.mem.Allocator, regions: []Region) void {
    if (regions.len == 0) return;
    for (regions) |region| allocator.free(region.name);
    allocator.free(regions);
}

pub fn formatLowPayload(allocator: std.mem.Allocator, regions: []const Region, state: ProtectState) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    errdefer writer.deinit();
    const w = &writer.writer;

    for (regions) |region| {
        try w.print("{s} {d}\n", .{ region.name, if (state == .active) region.capacity else 0 });
    }

    buf = writer.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

test "parse valid dmem.capacity lines and ignore blanks" {
    const regions = try parseCapacity(std.testing.allocator,
        \\drm/0000:03:00.0/vram0 8514437120
        \\
        \\drm/0000:03:00.0/stolen 67108864
    );
    defer freeRegions(std.testing.allocator, regions);

    try std.testing.expectEqual(@as(usize, 2), regions.len);
    try std.testing.expectEqualStrings("drm/0000:03:00.0/vram0", regions[0].name);
    try std.testing.expectEqual(@as(u64, 8514437120), regions[0].capacity);
    try std.testing.expectEqualStrings("drm/0000:03:00.0/stolen", regions[1].name);
    try std.testing.expectEqual(@as(u64, 67108864), regions[1].capacity);
}

test "parseCapacity ignores malformed lines and rejects non-numeric capacities" {
    try std.testing.expectError(error.InvalidCapacity, parseCapacity(std.testing.allocator,
        \\malformed
        \\drm/card0/vram0 nope
    ));

    const regions = try parseCapacity(std.testing.allocator,
        \\malformed
        \\drm/card0/vram0 42
    );
    defer freeRegions(std.testing.allocator, regions);

    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqualStrings("drm/card0/vram0", regions[0].name);
}

test "format dmem.low protected and zero payloads" {
    const regions = [_]Region{
        .{ .name = "drm/a/vram0", .capacity = 100 },
        .{ .name = "drm/a/stolen", .capacity = 7 },
    };

    const protected = try formatLowPayload(std.testing.allocator, &regions, .active);
    defer std.testing.allocator.free(protected);
    try std.testing.expectEqualStrings(
        \\drm/a/vram0 100
        \\drm/a/stolen 7
        \\
    , protected);

    const zero = try formatLowPayload(std.testing.allocator, &regions, .inactive);
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqualStrings(
        \\drm/a/vram0 0
        \\drm/a/stolen 0
        \\
    , zero);
}
