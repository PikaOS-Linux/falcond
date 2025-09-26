const std = @import("std");
const builtin = @import("builtin");
const Vector = std.meta.Vector;

pub const ParseError = error{
    InvalidSyntax,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
    InvalidIdentifier,
    UnknownField,
};

pub fn Parser(comptime T: type) type {
    return struct {
        const Self = @This();

        content: []const u8,
        pos: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, content: []const u8) Self {
            return .{
                .content = content,
                .allocator = allocator,
            };
        }

        fn skipWhitespace(self: *Self) void {
            const v_size = std.simd.suggestVectorLength(u8) orelse 32;
            const Vec = @Vector(v_size, u8);

            while (self.pos + v_size <= self.content.len) {
                const chunk: Vec = self.content[self.pos..][0..v_size].*;
                const spaces = chunk == @as(Vec, @splat(@as(u8, ' ')));
                const tabs = chunk == @as(Vec, @splat(@as(u8, '\t')));
                const newlines = chunk == @as(Vec, @splat(@as(u8, '\n')));
                const returns = chunk == @as(Vec, @splat(@as(u8, '\r')));
                const comments = chunk == @as(Vec, @splat(@as(u8, '#')));

                const whitespace = @reduce(.Or, spaces) or @reduce(.Or, tabs) or
                    @reduce(.Or, newlines) or @reduce(.Or, returns) or
                    @reduce(.Or, comments);
                if (!whitespace) break;

                if (@reduce(.Or, comments)) {
                    while (self.pos < self.content.len and self.content[self.pos] != '\n') : (self.pos += 1) {}
                    continue;
                }

                const space_mask = @select(u8, spaces, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));
                const tab_mask = @select(u8, tabs, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));
                const newline_mask = @select(u8, newlines, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));
                const return_mask = @select(u8, returns, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));

                const mask = space_mask | tab_mask | newline_mask | return_mask;
                const mask_bits = @reduce(.Or, mask);
                const leading = @ctz(mask_bits);
                if (leading == v_size) {
                    self.pos += v_size;
                } else {
                    self.pos += leading;
                    break;
                }
            }

            while (self.pos < self.content.len) : (self.pos += 1) {
                const c = self.content[self.pos];
                switch (c) {
                    ' ', '\t', '\r', '\n' => continue,
                    '#' => {
                        while (self.pos < self.content.len and self.content[self.pos] != '\n') : (self.pos += 1) {}
                    },
                    else => break,
                }
            }
        }

        fn parseString(self: *Self) ![]const u8 {
            if (self.pos >= self.content.len or self.content[self.pos] != '"') {
                std.log.err("Expected opening quote for string at position {}", .{self.pos});
                return error.InvalidSyntax;
            }

            self.pos += 1;
            var escaped = false;
            var result = std.ArrayListUnmanaged(u8){};
            errdefer result.deinit(self.allocator);

            const start_pos = self.pos;
            while (self.pos < self.content.len) : (self.pos += 1) {
                const c = self.content[self.pos];
                if (escaped) {
                    switch (c) {
                        '"' => try result.append(self.allocator, '"'),
                        '\\' => try result.append(self.allocator, '\\'),
                        'n' => try result.append(self.allocator, '\n'),
                        'r' => try result.append(self.allocator, '\r'),
                        't' => try result.append(self.allocator, '\t'),
                        else => {
                            std.log.err("Invalid escape sequence '\\{c}' at position {}", .{ c, self.pos });
                            return error.InvalidSyntax;
                        },
                    }
                    escaped = false;
                    continue;
                }
                switch (c) {
                    '"' => {
                        self.pos += 1;
                        return result.toOwnedSlice(self.allocator);
                    },
                    '\\' => {
                        escaped = true;
                    },
                    else => try result.append(self.allocator, c),
                }
            }

            std.log.err("Unterminated string starting at position {}, content: {s}", .{ start_pos, self.content[start_pos..@min(start_pos + 20, self.content.len)] });
            return error.UnterminatedString;
        }

        fn parseNumber(self: *Self) !i64 {
            self.skipWhitespace();
            const start = self.pos;
            while (self.pos < self.content.len) : (self.pos += 1) {
                const c = self.content[self.pos];
                if (!std.ascii.isDigit(c) and c != '-') break;
            }
            const num = std.fmt.parseInt(i64, self.content[start..self.pos], 10) catch return error.InvalidNumber;
            return num;
        }

        fn parseArray(self: *Self) ![]const i64 {
            if (self.pos >= self.content.len or self.content[self.pos] != '[')
                return error.InvalidSyntax;

            self.pos += 1;
            var values: [32]i64 = undefined;
            var count: usize = 0;

            while (self.pos < self.content.len) {
                self.skipWhitespace();
                if (self.content[self.pos] == ']') {
                    self.pos += 1;
                    return try self.allocator.dupe(i64, values[0..count]);
                }

                if (count >= values.len) return error.InvalidSyntax;
                const num = try self.parseNumber();
                values[count] = num;
                count += 1;

                self.skipWhitespace();
                if (self.content[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }
                if (self.content[self.pos] == ']') {
                    self.pos += 1;
                    return try self.allocator.dupe(i64, values[0..count]);
                }
                return error.InvalidSyntax;
            }
            return error.InvalidSyntax;
        }

        fn parseStringArray(self: *Self) ![]const []const u8 {
            if (self.pos >= self.content.len or self.content[self.pos] != '[')
                return error.InvalidSyntax;

            self.pos += 1;
            var values = std.ArrayListUnmanaged([]const u8){};
            errdefer {
                for (values.items) |str| {
                    self.allocator.free(str);
                }
                values.deinit(self.allocator);
            }

            while (self.pos < self.content.len) {
                self.skipWhitespace();
                if (self.content[self.pos] == ']') {
                    self.pos += 1;
                    return values.toOwnedSlice(self.allocator);
                }

                const str = self.parseString() catch |err| {
                    std.log.err("Failed to parse string at position {}: {s}", .{ self.pos, @errorName(err) });
                    return err;
                };
                try values.append(self.allocator, str);

                self.skipWhitespace();
                if (self.content[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }
                if (self.content[self.pos] == ']') {
                    self.pos += 1;
                    return values.toOwnedSlice(self.allocator);
                }
                std.log.err("Expected ',' or ']' but found '{c}' at position {}", .{ self.content[self.pos], self.pos });
                return error.InvalidSyntax;
            }
            std.log.err("Unterminated array at position {}", .{self.pos});
            return error.InvalidSyntax;
        }

        fn parseIdentifier(self: *Self) ![]const u8 {
            const start = self.pos;
            const v_size = std.simd.suggestVectorLength(u8) orelse 32;
            const Vec = @Vector(v_size, u8);

            while (self.pos + v_size <= self.content.len) {
                const chunk: Vec = self.content[self.pos..][0..v_size].*;

                const lower_bound = chunk >= @as(Vec, @splat(@as(u8, 'a')));
                const upper_bound = chunk <= @as(Vec, @splat(@as(u8, 'z')));
                const alpha_lower_mask = @select(u8, lower_bound, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0)))) &
                    @select(u8, upper_bound, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));

                const upper_lower = chunk >= @as(Vec, @splat(@as(u8, 'A')));
                const upper_upper = chunk <= @as(Vec, @splat(@as(u8, 'Z')));
                const alpha_upper_mask = @select(u8, upper_lower, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0)))) &
                    @select(u8, upper_upper, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));

                const digit_lower = chunk >= @as(Vec, @splat(@as(u8, '0')));
                const digit_upper = chunk <= @as(Vec, @splat(@as(u8, '9')));
                const digit_mask = @select(u8, digit_lower, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0)))) &
                    @select(u8, digit_upper, @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));

                const underscore_mask = @select(u8, chunk == @as(Vec, @splat(@as(u8, '_'))), @as(Vec, @splat(@as(u8, 1))), @as(Vec, @splat(@as(u8, 0))));

                const mask = alpha_lower_mask | alpha_upper_mask | digit_mask | underscore_mask;
                const valid = @reduce(.Or, mask) != 0;
                if (!valid) break;

                const mask_bits = @reduce(.Or, mask);
                const leading = @ctz(mask_bits);
                if (leading == v_size) {
                    self.pos += v_size;
                } else {
                    self.pos += leading;
                    break;
                }
            }

            while (self.pos < self.content.len) : (self.pos += 1) {
                const c = self.content[self.pos];
                if (!std.ascii.isAlphabetic(c) and !std.ascii.isDigit(c) and c != '_') break;
            }

            if (start == self.pos) return error.InvalidIdentifier;
            return self.content[start..self.pos];
        }

        pub fn parse(self: *Self) !T {
            var result: T = std.mem.zeroInit(T, .{});

            while (self.pos < self.content.len) {
                self.skipWhitespace();
                if (self.pos >= self.content.len) break;

                const field_name = try self.parseIdentifier();
                self.skipWhitespace();

                if (self.pos >= self.content.len or self.content[self.pos] != '=')
                    return error.InvalidSyntax;
                self.pos += 1;

                self.skipWhitespace();

                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, field_name, field.name)) {
                        switch (@typeInfo(field.type)) {
                            .bool => {
                                const ident = try self.parseIdentifier();
                                if (std.mem.eql(u8, ident, "true")) {
                                    @field(result, field.name) = true;
                                } else if (std.mem.eql(u8, ident, "false")) {
                                    @field(result, field.name) = false;
                                } else return error.InvalidSyntax;
                            },
                            .int => {
                                @field(result, field.name) = @intCast(try self.parseNumber());
                            },
                            .array => |array_info| {
                                switch (@typeInfo(array_info.child)) {
                                    i64 => {
                                        const array = try self.parseArray();
                                        if (array.len > array_info.len) return error.InvalidSyntax;
                                        @field(result, field.name) = undefined;
                                        var dest = &@field(result, field.name);
                                        @memcpy(dest[0..array.len], array);
                                    },
                                    else => return error.InvalidSyntax,
                                }
                            },
                            .@"enum" => {
                                const ident = try self.parseIdentifier();
                                inline for (std.meta.fields(field.type)) |enum_field| {
                                    if (std.mem.eql(u8, ident, enum_field.name)) {
                                        @field(result, field.name) = @field(field.type, enum_field.name);
                                        break;
                                    }
                                }
                            },
                            .optional => |opt_info| {
                                switch (@typeInfo(opt_info.child)) {
                                    .@"enum" => {
                                        const ident = try self.parseIdentifier();
                                        inline for (std.meta.fields(opt_info.child)) |enum_field| {
                                            if (std.mem.eql(u8, ident, enum_field.name)) {
                                                @field(result, field.name) = @field(opt_info.child, enum_field.name);
                                                break;
                                            }
                                        }
                                    },
                                    .pointer => |ptr_info| {
                                        if (ptr_info.size != .slice) {
                                            return error.InvalidSyntax;
                                        }

                                        if (ptr_info.child == u8) {
                                            const str = try self.parseString();
                                            @field(result, field.name) = str;
                                        } else {
                                            return error.InvalidSyntax;
                                        }
                                    },
                                    else => return error.InvalidSyntax,
                                }
                            },
                            .pointer => |ptr_info| {
                                if (ptr_info.size != .slice) {
                                    return error.InvalidSyntax;
                                }

                                if (ptr_info.child == []const u8) {
                                    @field(result, field.name) = try self.parseStringArray();
                                } else switch (ptr_info.child) {
                                    u8 => {
                                        @field(result, field.name) = try self.parseString();
                                    },
                                    i64 => {
                                        @field(result, field.name) = try self.parseArray();
                                    },
                                    else => {
                                        return error.InvalidSyntax;
                                    },
                                }
                            },
                            else => return error.InvalidSyntax,
                        }
                        break;
                    }
                }
            }

            return result;
        }
    };
}

// Example usage:
const Config = struct {
    // Boolean tests
    bool_true: bool = false,
    bool_false: bool = true,

    // Integer tests
    int_zero: i64 = 1,
    int_positive: i64 = 0,
    int_negative: i64 = 42,
    int_small: u32 = 16,

    // Array tests
    array_empty: [4]i64 = .{ 0, 0, 0, 0 },
    array_full: [4]i64 = .{ 0, 1, 2, 3 },
    array_partial: [4]i64 = .{ 9, 8, 0, 0 },

    // Enum tests
    enum_first: enum { First, Second, Third } = .Second,
    enum_last: enum { One, Two, Last } = .One,
    lscpu_core_strategy: enum { HighestFreq, Sequential } = .HighestFreq,

    // String tests
    string_empty: []const u8 = "",
    string_simple: []const u8 = "hello",
    string_spaces: []const u8 = "hello world",
    string_special: []const u8 = "hello_123",
};

test "parse config" {
    const content =
        \\bool_true = true
        \\bool_false = false
        \\int_zero = 0
        \\int_positive = 42
        \\int_negative = -123
        \\int_small = 16
        \\array_empty = []
        \\array_full = [0,1,2,3]
        \\array_partial = [9,8]
        \\enum_first = First
        \\enum_last = Last
        \\lscpu_core_strategy = HighestFreq
        \\string_empty = ""
        \\string_simple = "hello"
        \\string_spaces = "hello world"
        \\string_special = "hello_123"
    ;

    var parser = Parser(Config).init(std.heap.page_allocator, content);
    const config = try parser.parse();

    // Boolean tests
    try std.testing.expect(config.bool_true);
    try std.testing.expect(!config.bool_false);

    // Integer tests
    try std.testing.expectEqual(@as(i64, 0), config.int_zero);
    try std.testing.expectEqual(@as(i64, 42), config.int_positive);
    try std.testing.expectEqual(@as(i64, -123), config.int_negative);
    try std.testing.expectEqual(@as(u32, 16), config.int_small);

    // Array tests
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 0, 0, 0 }, &config.array_empty);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 1, 2, 3 }, &config.array_full);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 9, 8, 0, 0 }, &config.array_partial);

    // Enum tests
    try std.testing.expectEqual(@as(@TypeOf(config.enum_first), .First), config.enum_first);
    try std.testing.expectEqual(@as(@TypeOf(config.enum_last), .Last), config.enum_last);
    try std.testing.expectEqual(@as(@TypeOf(config.lscpu_core_strategy), .HighestFreq), config.lscpu_core_strategy);

    // String tests
    try std.testing.expectEqualStrings("", config.string_empty);
    try std.testing.expectEqualStrings("hello", config.string_simple);
    try std.testing.expectEqualStrings("hello world", config.string_spaces);
    try std.testing.expectEqualStrings("hello_123", config.string_special);
}

test "parse with missing fields" {
    const TestConfig = struct {
        name: []const u8 = "default",
        cores: []const i64 = &[_]i64{ 0, 1 },
        enabled: bool = true,
        count: u32 = 42,
    };

    const content =
        \\name = "test"
        \\cores = [5,6,7]
    ;

    var parser = Parser(TestConfig).init(std.testing.allocator, content);
    const config = try parser.parse();
    defer {
        std.testing.allocator.free(config.name);
        std.testing.allocator.free(config.cores);
    }

    try std.testing.expectEqualStrings("test", config.name);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 5, 6, 7 }, config.cores);
    try std.testing.expect(config.enabled == true); // default value
    try std.testing.expect(config.count == 42); // default value
}
