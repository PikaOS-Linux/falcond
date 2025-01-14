const std = @import("std");
const types = @import("types.zig");
const Profile = types.Profile;
const Config = @import("../config/config.zig").Config;

// Don't match Wine/Proton infrastructure
// const system_processes = [_][]const u8{
//     "steam.exe",
//     "services.exe",
//     "winedevice.exe",
//     "plugplay.exe",
//     "svchost.exe",
//     "explorer.exe",
//     "rpcss.exe",
//     "tabtip.exe",
//     "wineboot.exe",
//     "rundll32.exe",
//     "iexplore.exe",
//     "conhost.exe",
//     "crashpad_handler.exe",
//     "iscriptevaluator.exe",
//     "VC_redist.x86.exe",
//     "VC_redist.x64.exe",
//     "cmd.exe",
//     "REDEngineErrorReporter.exe",
//     "REDprelauncher.exe",
//     "SteamService.exe",
//     "UnityCrashHandler64.exe",
//     "start.exe",
// };

pub fn isProtonParent(arena: std.mem.Allocator, pid: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const status_path = try std.fmt.bufPrint(&path_buf, "/proc/{s}/status", .{pid});

    const file = std.fs.openFileAbsolute(status_path, .{}) catch |err| {
        std.log.debug("Failed to open {s}: {}", .{ status_path, err });
        return switch (err) {
            error.AccessDenied, error.FileNotFound => false,
            else => err,
        };
    };
    defer file.close();

    const content = try file.readToEndAlloc(arena, std.math.maxInt(usize));

    const ppid_line = std.mem.indexOf(u8, content, "PPid:") orelse return false;
    const line_end = std.mem.indexOfScalarPos(u8, content, ppid_line, '\n') orelse content.len;
    const ppid_start = ppid_line + 5; // Length of "PPid:"
    const ppid = std.mem.trim(u8, content[ppid_start..line_end], " \t");

    const parent_cmdline_path = try std.fmt.bufPrint(&path_buf, "/proc/{s}/cmdline", .{ppid});
    const parent_file = std.fs.openFileAbsolute(parent_cmdline_path, .{}) catch |err| {
        std.log.debug("Failed to open parent cmdline {s}: {}", .{ parent_cmdline_path, err });
        return switch (err) {
            error.AccessDenied, error.FileNotFound => false,
            else => err,
        };
    };
    defer parent_file.close();

    const parent_content = try parent_file.readToEndAlloc(arena, std.math.maxInt(usize));
    return std.mem.indexOf(u8, parent_content, "proton") != null;
}

pub fn isProtonGame(process_name: []const u8, config: Config) bool {
    if (!std.mem.endsWith(u8, process_name, ".exe")) return false;

    for (config.system_processes) |sys_proc| {
        if (std.mem.eql(u8, process_name, sys_proc)) {
            return false;
        }
    }

    return true;
}

pub fn matchProcess(profiles: []Profile, proton_profile: ?*const Profile, arena: std.mem.Allocator, pid: []const u8, process_name: []const u8, config: Config) !?*const Profile {
    const is_exe = std.mem.endsWith(u8, process_name, ".exe");
    var match: ?*const Profile = null;

    for (profiles) |*profile| {
        const is_match = profile != proton_profile and profile.matches(process_name);
        if (is_match) {
            std.log.info("Matched profile {s} for process {s}", .{ profile.name, process_name });
            match = profile;
            break;
        }
    }

    const should_check_proton = match == null and
        is_exe and
        proton_profile != null;

    if (should_check_proton) {
        const is_system = for (config.system_processes) |sys_proc| {
            if (std.mem.eql(u8, process_name, sys_proc)) break true;
        } else false;

        if (!is_system) {
            const is_proton = try isProtonParent(arena, pid);
            if (is_proton) {
                std.log.info("Found Proton game: {s}", .{process_name});
                match = proton_profile;
            }
        }
    }

    return match;
}
