const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path options (comptime, zero runtime cost)
    const config_path = b.option([]const u8, "config-path", "Path to config file (default: /etc/falcond/config.conf)") orelse "/etc/falcond/config.conf";
    const profiles_dir = b.option([]const u8, "profiles-dir", "Path to profiles directory (default: /usr/share/falcond/profiles)") orelse "/usr/share/falcond/profiles";
    const user_profiles_dir = b.option([]const u8, "user-profiles-dir", "Path to user profiles directory (default: /usr/share/falcond/profiles/user)") orelse "/usr/share/falcond/profiles/user";
    const system_conf_path = b.option([]const u8, "system-conf-path", "Path to system.conf (default: /usr/share/falcond/system.conf)") orelse "/usr/share/falcond/system.conf";
    const status_file = b.option([]const u8, "status-file", "Path to status file (default: /var/lib/falcond/status)") orelse "/var/lib/falcond/status";
    const tmp_status_file = b.option([]const u8, "tmp-status-file", "Path to tmp status file (default: /tmp/falcond_status)") orelse "/tmp/falcond_status";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "config_path", config_path);
    build_options.addOption([]const u8, "profiles_dir", profiles_dir);
    build_options.addOption([]const u8, "user_profiles_dir", user_profiles_dir);
    build_options.addOption([]const u8, "system_conf_path", system_conf_path);
    build_options.addOption([]const u8, "status_file", status_file);
    build_options.addOption([]const u8, "tmp_status_file", tmp_status_file);

    // Dependencies
    const otter_conf = b.dependency("otter_conf", .{
        .target = target,
        .optimize = optimize,
    }).module("otter_conf");

    const otter_desktop_dep = b.dependency("otter_desktop", .{
        .target = target,
        .optimize = optimize,
        .enable_pipewire = false,
    });
    const otter_desktop = otter_desktop_dep.module("otter_desktop");

    const otter_utils = b.dependency("otter_utils", .{
        .target = target,
        .optimize = optimize,
    }).module("otter_utils");

    const main_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    main_module.addImport("otter_conf", otter_conf);
    main_module.addImport("otter_desktop", otter_desktop);
    main_module.addImport("otter_utils", otter_utils);
    main_module.addImport("build_options", build_options.createModule());

    const exe = b.addExecutable(.{
        .name = "falcond",
        .root_module = main_module,
    });

    exe.bundle_compiler_rt = true;

    b.installArtifact(exe);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("otter_conf", otter_conf);
    test_module.addImport("otter_desktop", otter_desktop);
    test_module.addImport("otter_utils", otter_utils);
    test_module.addImport("build_options", build_options.createModule());

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
