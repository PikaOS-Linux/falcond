const std = @import("std");
const os = std.os;

pub const RunnerError = error{
    CommandFailed,
    SpawnFailed,
    EnvVarNotFound,
} || std.process.Child.SpawnError;

/// Runs a script in a non-blocking manner for a specific process
/// If proc_id is provided, it will try to run the script as the user who owns that process
/// If user_id is provided, it will use that directly instead of looking up the user for the process
pub fn runScript(allocator: std.mem.Allocator, script: []const u8, proc_id: []const u8, user_id: ?os.linux.uid_t) void {
    if (script.len == 0) {
        return;
    }
    std.log.info("Running script: {s}", .{script});

    // When running as root, we need to de-escalate to a regular user
    var modified_script = script;
    var script_buf: ?[]u8 = null;
    defer if (script_buf) |buf| allocator.free(buf);

    if (os.linux.geteuid() == 0) {
        const process_user_id = if (user_id) |uid| uid else findUserForProcess(proc_id) catch |err| {
            std.log.warn("Could not find user for process {s}: {}", .{ proc_id, err });
            return;
        };

        // We have a user ID, try to prepare the script
        script_buf = prepareScriptForUser(allocator, script, process_user_id) catch |prepare_err| {
            std.log.warn("Failed to prepare script for user {d}: {}", .{ process_user_id, prepare_err });
            return;
        };

        modified_script = script_buf.?;
    }

    const argv = [_][]const u8{
        "sh",
        "-c",
        modified_script,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.spawn() catch |err| {
        std.log.warn("Failed to spawn script process: {}", .{err});
        return;
    };
}

/// Find the user ID that owns a specific process
pub fn findUserForProcess(pid: []const u8) !os.linux.uid_t {
    // Open the /proc/[pid]/status file to get the UID
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const status_path = try std.fmt.bufPrint(&path_buf, "/proc/{s}/status", .{pid});

    const file = std.fs.openFileAbsolute(status_path, .{}) catch |err| {
        std.log.err("Failed to open {s}: {}", .{ status_path, err });
        return error.FailedToFindUser;
    };
    defer file.close();

    const content = try file.readToEndAlloc(std.heap.page_allocator, std.math.maxInt(usize));
    defer std.heap.page_allocator.free(content);

    // Find the Uid line in the status file
    const uid_line = std.mem.indexOf(u8, content, "Uid:") orelse {
        std.log.err("Could not find Uid line in /proc/{s}/status", .{pid});
        return error.FailedToFindUser;
    };

    // Parse the real UID (first number after "Uid:")
    const line_end = std.mem.indexOfScalarPos(u8, content, uid_line, '\n') orelse content.len;
    const uid_start = uid_line + 4; // Length of "Uid:"
    const uid_str = std.mem.trim(u8, content[uid_start..line_end], " \t");

    // The UID line has format "Uid: real effective saved fs"
    var iter = std.mem.tokenizeAny(u8, uid_str, " \t");
    const real_uid_str = iter.next() orelse {
        std.log.err("Could not parse UID from /proc/{s}/status", .{pid});
        return error.FailedToFindUser;
    };

    const uid = std.fmt.parseInt(os.linux.uid_t, real_uid_str, 10) catch |err| {
        std.log.err("Failed to parse UID '{s}' from /proc/{s}/status: {}", .{ real_uid_str, pid, err });
        return error.FailedToFindUser;
    };

    return uid;
}

/// Prepare a script to run with the environment of a specific user
fn prepareScriptForUser(allocator: std.mem.Allocator, script: []const u8, user_id: os.linux.uid_t) ![]u8 {
    // The correct syntax for sudo with a user ID is "sudo -u '#1000'" (with quotes around the #UID)
    return try std.fmt.allocPrint(allocator, "sudo -u '#{d}' DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{d}/bus {s}", .{ user_id, user_id, script });
}
