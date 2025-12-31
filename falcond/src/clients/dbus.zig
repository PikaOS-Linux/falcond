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
    is_system: bool,
    target_uid: ?u32,

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
            .is_system = true,
            .target_uid = null,
        };
    }

    pub fn initSession(
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
            .is_system = false,
            .target_uid = null,
        };
    }

    pub fn withUser(self: DBus, uid: ?u32) DBus {
        var copy = self;
        copy.target_uid = uid;
        return copy;
    }

    fn runBusctl(self: *const DBus, args: []const []const u8) !std.process.Child.RunResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var argv = std.ArrayListUnmanaged([]const u8){};

        if (!self.is_system and self.target_uid != null) {
            try argv.append(alloc, "sudo");
            try argv.append(alloc, "-u");
            try argv.append(alloc, try std.fmt.allocPrint(alloc, "#{d}", .{self.target_uid.?}));
            try argv.append(alloc, try std.fmt.allocPrint(alloc, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus", .{self.target_uid.?}));
        }

        try argv.append(alloc, "busctl");
        if (self.is_system) {
            try argv.append(alloc, "--system");
        } else {
            try argv.append(alloc, "--user");
        }

        try argv.appendSlice(alloc, args);

        const max_output_size = 1024 * 1024; // 1MB
        return std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .max_output_bytes = max_output_size,
        });
    }

    /// Get a property value as a string
    pub fn getProperty(self: *const DBus, property: []const u8) ![]const u8 {
        const args = [_][]const u8{
            "get-property",
            self.bus_name,
            self.object_path,
            self.interface,
            property,
        };

        const output = try self.runBusctl(&args);
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
        var result = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (result.items) |item| {
                self.allocator.free(item);
            }
            result.deinit(self.allocator);
        }

        const args = [_][]const u8{
            "get-property",
            self.bus_name,
            self.object_path,
            self.interface,
            property,
        };

        const output = try self.runBusctl(&args);
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
            try result.append(self.allocator, try self.allocator.dupe(u8, value));
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Set a property value
    pub fn setProperty(self: *const DBus, property: []const u8, value: []const u8) !void {
        const args = [_][]const u8{
            "set-property",
            self.bus_name,
            self.object_path,
            self.interface,
            property,
            "s",
            value,
        };

        const output = try self.runBusctl(&args);
        defer self.allocator.free(output.stderr);
        defer self.allocator.free(output.stdout);

        if (output.term.Exited != 0) {
            std.log.err("busctl failed: {s}", .{output.stderr});
            return DBusError.CommandFailed;
        }
    }

    /// Call a DBus method and return the output (stdout)
    /// Caller owns the returned memory
    pub fn callMethod(self: *const DBus, method: []const u8, args: []const []const u8) ![]u8 {
        var call_args = std.ArrayListUnmanaged([]const u8){};
        defer call_args.deinit(self.allocator);

        try call_args.appendSlice(self.allocator, &[_][]const u8{
            "call",
            self.bus_name,
            self.object_path,
            self.interface,
            method,
        });

        if (args.len > 0) {
            try call_args.appendSlice(self.allocator, args);
        }

        const output = try self.runBusctl(call_args.items);
        defer self.allocator.free(output.stderr);

        if (output.term.Exited != 0) {
            std.log.err("busctl failed: {s}", .{output.stderr});
            self.allocator.free(output.stdout);
            return DBusError.CommandFailed;
        }

        return output.stdout;
    }
};
