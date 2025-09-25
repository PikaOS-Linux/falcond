const std = @import("std");

pub const DBusError = error{
    CommandFailed,
    ParseError,
    InvalidValue,
    NoConnection,
} || std.fs.File.OpenError || std.posix.WriteError || std.posix.ReadError || std.process.Child.RunError || std.process.Child.SpawnError || error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    OperationAborted,
    WouldBlock,
    InvalidHandle,
    Unexpected,
    InputOutput,
    OutOfMemory,
    ResourceLimitReached,
    StderrStreamTooLong,
    StdoutStreamTooLong,
    CurrentWorkingDirectoryUnlinked,
    InvalidBatchScriptArg,
    InvalidExe,
    FileSystem,
    Overflow,
    InvalidCharacter,
    InvalidUserId,
    PermissionDenied,
    ProcessAlreadyExec,
    InvalidProcessGroupId,
    InvalidName,
    WaitAbandoned,
    WaitTimeOut,
    NetworkSubsystemFailed,
};

pub const DBus = struct {
    allocator: std.mem.Allocator,
    bus_name: []const u8,
    object_path: []const u8,
    interface: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        bus_name: []const u8,
        object_path: []const u8,
        interface: []const u8,
    ) DBus {
        return .{
            .allocator = allocator,
            .bus_name = bus_name,
            .object_path = object_path,
            .interface = interface,
        };
    }

    /// Get a property value as a string
    pub fn getProperty(self: *const DBus, property: []const u8) ![]const u8 {
        var argv = [_][]const u8{
            "busctl",
            "--system",
            "get-property",
            self.bus_name,
            self.object_path,
            self.interface,
            property,
        };

        const max_output_size = 1024 * 1024; // 1MB should be enough
        const output = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
            .max_output_bytes = max_output_size,
        });
        defer self.allocator.free(output.stderr);
        defer self.allocator.free(output.stdout);

        if (output.term.Exited != 0) {
            std.log.err("busctl failed: {s}", .{output.stderr});
            return DBusError.CommandFailed;
        }

        // busctl outputs values in two formats:
        // 1. String: "s \"value\""
        // 2. Integer: "u 123"
        const trimmed = std.mem.trim(u8, output.stdout, " \n\r\t");

        // Try string format first
        var it = std.mem.splitScalar(u8, trimmed, '"');
        _ = it.next(); // Skip type
        if (it.next()) |value| {
            return self.allocator.dupe(u8, value);
        }

        // Try integer format
        it = std.mem.splitScalar(u8, trimmed, ' ');
        _ = it.next(); // Skip type
        const value = it.next() orelse {
            // If property doesn't exist or is empty
            if (std.mem.indexOf(u8, output.stdout, "Unknown property") != null) {
                return self.allocator.dupe(u8, "");
            }
            return DBusError.ParseError;
        };

        return self.allocator.dupe(u8, value);
    }

    /// Get a property value as a string array
    pub fn getPropertyArray(self: *const DBus, property: []const u8) ![][]const u8 {
        var result = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer {
            for (result.items) |item| {
                self.allocator.free(item);
            }
            result.deinit();
        }

        const argv = [_][]const u8{
            "busctl",
            "--system",
            "get-property",
            self.bus_name,
            self.object_path,
            self.interface,
            property,
        };

        const max_output_size = 1024 * 1024; // 1MB should be enough
        const output = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
            .max_output_bytes = max_output_size,
        });
        defer self.allocator.free(output.stderr);
        defer self.allocator.free(output.stdout);

        if (output.term.Exited != 0) {
            std.log.err("busctl failed: {s}", .{output.stderr});
            return DBusError.CommandFailed;
        }

        // busctl outputs arrays in the format:
        // as 2 "value1" "value2"
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, output.stdout, " \n\r\t"), '"');
        _ = it.next(); // Skip type + count

        while (it.next()) |value| {
            // Skip empty strings and spaces between quotes
            if (value.len == 0 or std.mem.eql(u8, std.mem.trim(u8, value, " "), "")) continue;
            try result.append(try self.allocator.dupe(u8, value));
        }

        return result.toOwnedSlice();
    }

    /// Set a property value
    pub fn setProperty(self: *const DBus, property: []const u8, value: []const u8) !void {
        const argv = [_][]const u8{
            "busctl",
            "--system",
            "set-property",
            self.bus_name,
            self.object_path,
            self.interface,
            property,
            "s",
            value,
        };

        const max_output_size = 1024; // Small size since we don't expect much output
        const output = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &argv,
            .max_output_bytes = max_output_size,
        });
        defer self.allocator.free(output.stderr);
        defer self.allocator.free(output.stdout);

        if (output.term.Exited != 0) {
            std.log.err("busctl failed: {s}", .{output.stderr});
            return DBusError.CommandFailed;
        }
    }

    /// Call a DBus method
    pub fn callMethod(self: *const DBus, method: []const u8, args: []const []const u8) !void {
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.appendSlice(&[_][]const u8{
            "busctl",
            "--system",
            "call",
            self.bus_name,
            self.object_path,
            self.interface,
            method,
        });

        try argv.appendSlice(args);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);

        if (result.term.Exited != 0) {
            std.log.err("busctl failed: {s}", .{result.stderr});
            return DBusError.CommandFailed;
        }
    }
};
