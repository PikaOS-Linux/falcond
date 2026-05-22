const std = @import("std");
const otter_utils = @import("otter_utils");
const capacity_mod = @import("dmemcg/capacity.zig");
const path_mod = @import("dmemcg/path.zig");

const log = std.log.scoped(.dmemcg);
inline fn ioGlobal() std.Io {
    return otter_utils.io.get();
}

const cgroup_root = path_mod.cgroup_root;
const capacity_path = cgroup_root ++ "/dmem.capacity";
const root_controllers_path = cgroup_root ++ "/cgroup.controllers";
const max_file_size = 128 * 1024;

pub const Region = capacity_mod.Region;
pub const ProtectState = capacity_mod.ProtectState;
pub const parseCapacity = capacity_mod.parseCapacity;
pub const freeRegions = capacity_mod.freeRegions;
pub const formatLowPayload = capacity_mod.formatLowPayload;

pub const parseUnifiedCgroupPath = path_mod.parseUnifiedCgroupPath;
pub const sanitizeProfileName = path_mod.sanitizeProfileName;
pub const canonicalizeSourcePath = path_mod.canonicalizeSourcePath;
pub const cgroupFsPathFromUnified = path_mod.cgroupFsPathFromUnified;

pub const Availability = enum {
    available,
    no_cgroup_v2,
    no_dmem_controller,
    no_capacity_file,
    no_regions,
    hierarchy_not_enabled,
    cannot_prepare_parent,
    permission_denied,
};

pub const ParentRecord = struct {
    source_path: []const u8,
    other_child_path: []const u8,
    prepared: bool = false,
    subtree_dmem_enabled: bool = false,
    ref_count: u32 = 0,
    last_error: ?Availability = null,
};

pub const ProfileCgroupRecord = struct {
    source_path: []const u8,
    child_path: []const u8,
    profile_idx: u8,
    profile_name: []const u8,
    ref_count: u32 = 0,
    protected: bool = false,
    zeroed: bool = true,
    last_error: ?Availability = null,
};

pub const PidRecord = struct {
    pid: u32,
    profile_idx: u8,
    source_path: []const u8,
    child_path: []const u8,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    availability: Availability,
    regions: []Region,
    pid_records: std.AutoHashMap(u32, PidRecord),
    parent_records: std.StringHashMap(ParentRecord),
    profile_cgroups: std.StringHashMap(ProfileCgroupRecord),
    last_error: ?Availability = null,

    pub fn init(allocator: std.mem.Allocator) Manager {
        var availability: Availability = .available;
        var regions: []Region = &.{};

        if (std.Io.Dir.accessAbsolute(ioGlobal(), cgroup_root, .{})) |_| {} else |err| {
            availability = mapAccessError(err, .no_cgroup_v2);
        }

        if (availability == .available) {
            const controllers = readFileAlloc(allocator, root_controllers_path) catch |err| blk: {
                availability = mapReadError(err, .no_dmem_controller);
                break :blk null;
            };
            if (controllers) |bytes| {
                defer allocator.free(bytes);
                if (!containsToken(bytes, "dmem")) {
                    availability = .no_dmem_controller;
                }
            }
        }

        if (availability == .available) {
            const capacity = readFileAlloc(allocator, capacity_path) catch |err| blk: {
                availability = mapReadError(err, .no_capacity_file);
                break :blk null;
            };
            if (capacity) |bytes| {
                defer allocator.free(bytes);
                regions = parseCapacity(allocator, bytes) catch |err| blk: {
                    log.debug("failed to parse dmem.capacity: {}", .{err});
                    availability = .no_regions;
                    break :blk &.{};
                };
                if (regions.len == 0) availability = .no_regions;
            }
        }

        return .{
            .allocator = allocator,
            .availability = availability,
            .regions = regions,
            .pid_records = std.AutoHashMap(u32, PidRecord).init(allocator),
            .parent_records = std.StringHashMap(ParentRecord).init(allocator),
            .profile_cgroups = std.StringHashMap(ProfileCgroupRecord).init(allocator),
            .last_error = if (availability == .available) null else availability,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.reset();
        freeRegions(self.allocator, self.regions);
        self.pid_records.deinit();
        self.parent_records.deinit();
        self.profile_cgroups.deinit();
    }

    pub fn trackPid(self: *Manager, profile_idx: u8, profile_name: []const u8, pid: u32, state: ProtectState) void {
        if (self.availability != .available) return;

        const current_path = readPidCgroupPath(self.allocator, pid) catch |err| {
            self.noteError(mapTrackError(err));
            return;
        };
        defer self.allocator.free(current_path);

        const source_slice = canonicalizeSourcePath(current_path);
        const source_path = self.allocator.dupe(u8, source_slice) catch {
            self.noteError(.cannot_prepare_parent);
            return;
        };
        defer self.allocator.free(source_path);

        self.trackPidInSource(profile_idx, profile_name, pid, source_path, state) catch |err| {
            self.noteError(mapTrackError(err));
        };
    }

    pub fn releasePid(self: *Manager, profile_idx: u8, pid: u32) void {
        const removed = self.pid_records.fetchRemove(pid) orelse return;
        defer self.freePidRecord(removed.value);

        if (removed.value.profile_idx != profile_idx) return;

        if (self.parent_records.getPtr(removed.value.source_path)) |parent| {
            if (parent.ref_count > 0) parent.ref_count -= 1;
        }

        const key = removed.value.child_path;
        if (self.profile_cgroups.getPtr(key)) |record| {
            if (record.ref_count > 0) record.ref_count -= 1;
            if (record.ref_count == 0) {
                self.writeLow(record, .inactive);
            }
        }
    }

    pub fn activateProfile(self: *Manager, profile_idx: u8) void {
        var it = self.profile_cgroups.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.profile_idx == profile_idx) {
                self.writeLow(entry.value_ptr, .active);
            }
        }
    }

    pub fn deactivateProfile(self: *Manager, profile_idx: u8) void {
        var it = self.profile_cgroups.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.profile_idx == profile_idx) {
                self.writeLow(entry.value_ptr, .inactive);
            }
        }
    }

    pub fn reconcile(self: *Manager) void {
        if (self.availability != .available) return;

        self.removeVanishedCgroups();

        var it = self.pid_records.iterator();
        while (it.next()) |entry| {
            movePidToChild(self.allocator, entry.key_ptr.*, entry.value_ptr.child_path) catch {};
        }

        var pit = self.profile_cgroups.iterator();
        while (pit.next()) |entry| {
            self.writeLow(entry.value_ptr, if (entry.value_ptr.protected) .active else .inactive);
        }
    }

    pub fn reset(self: *Manager) void {
        var pcg_it = self.profile_cgroups.iterator();
        while (pcg_it.next()) |entry| {
            self.writeLow(entry.value_ptr, .inactive);
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.source_path);
            self.allocator.free(entry.value_ptr.profile_name);
        }
        self.profile_cgroups.clearRetainingCapacity();

        var parent_it = self.parent_records.iterator();
        while (parent_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.other_child_path);
        }
        self.parent_records.clearRetainingCapacity();

        var pid_it = self.pid_records.iterator();
        while (pid_it.next()) |entry| {
            self.freePidRecord(entry.value_ptr.*);
        }
        self.pid_records.clearRetainingCapacity();
    }

    pub fn trackPidForTest(self: *Manager, profile_idx: u8, profile_name: []const u8, pid: u32, child_path: []const u8, state: ProtectState) void {
        const source_path = canonicalizeSourcePath(child_path);
        self.trackPidInSource(profile_idx, profile_name, pid, source_path, state) catch unreachable;
    }

    fn trackPidInSource(self: *Manager, profile_idx: u8, profile_name: []const u8, pid: u32, source_path: []const u8, state: ProtectState) !void {
        var new_pid_record = true;
        if (self.pid_records.get(pid)) |old| {
            if (old.profile_idx == profile_idx and std.mem.eql(u8, old.source_path, source_path)) {
                new_pid_record = false;
            } else {
                self.releasePid(old.profile_idx, pid);
            }
        }

        var parent = try self.ensureParentRecord(source_path);
        const child_path = try self.profileChildPath(parent.source_path, profile_idx, profile_name);
        defer self.allocator.free(child_path);

        var record = try self.ensureProfileRecord(parent.source_path, child_path, profile_idx, profile_name);

        if (new_pid_record) {
            const pid_record = PidRecord{
                .pid = pid,
                .profile_idx = profile_idx,
                .source_path = try self.allocator.dupe(u8, parent.source_path),
                .child_path = try self.allocator.dupe(u8, record.child_path),
            };
            errdefer self.freePidRecord(pid_record);
            try self.pid_records.put(pid, pid_record);

            parent.ref_count += 1;
            record.ref_count += 1;
        }

        if (self.availability == .available) {
            if (!parent.prepared) {
                self.prepareParentForDmem(parent, record, pid) catch |err| {
                    const mapped = mapTrackError(err);
                    parent.last_error = mapped;
                    record.last_error = mapped;
                    self.noteError(mapped);
                    return;
                };
            } else {
                try makeDir(record.child_path);
            }
        }

        if (self.availability == .available) {
                try movePidToChild(self.allocator, pid, record.child_path);
        }

        self.writeLow(record, state);
    }

    fn ensureParentRecord(self: *Manager, source_path: []const u8) !*ParentRecord {
        if (self.parent_records.getPtr(source_path)) |record| return record;

        const key = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(key);

        const other_child = try std.fmt.allocPrint(self.allocator, "{s}/falcond-dmem-other", .{source_path});
        errdefer self.allocator.free(other_child);

        try self.parent_records.put(key, .{
            .source_path = key,
            .other_child_path = other_child,
        });
        return self.parent_records.getPtr(key).?;
    }

    fn ensureProfileRecord(
        self: *Manager,
        source_path: []const u8,
        child_path: []const u8,
        profile_idx: u8,
        profile_name: []const u8,
    ) !*ProfileCgroupRecord {
        if (self.profile_cgroups.getPtr(child_path)) |record| return record;

        const key = try self.allocator.dupe(u8, child_path);
        errdefer self.allocator.free(key);

        const source_copy = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(source_copy);

        const name_copy = try self.allocator.dupe(u8, profile_name);
        errdefer self.allocator.free(name_copy);

        try self.profile_cgroups.put(key, .{
            .source_path = source_copy,
            .child_path = key,
            .profile_idx = profile_idx,
            .profile_name = name_copy,
        });
        return self.profile_cgroups.getPtr(key).?;
    }

    fn profileChildPath(self: *Manager, source_path: []const u8, profile_idx: u8, profile_name: []const u8) ![]const u8 {
        var prefix_buf: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "falcond-dmem-p{d:0>2}-", .{profile_idx});
        var safe_buf: [path_mod.max_child_name_len]u8 = undefined;
        const safe_limit = if (prefix.len >= path_mod.max_child_name_len) 0 else path_mod.max_child_name_len - prefix.len;
        const safe = path_mod.sanitizeProfileName(safe_buf[0..safe_limit], profile_name);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ source_path, prefix, safe });
    }

    fn prepareParentForDmem(self: *Manager, parent: *ParentRecord, first: *ProfileCgroupRecord, first_pid: u32) !void {
        if (!try containsController(self.allocator, parent.source_path, "dmem")) {
            try enableDmemOnSafeAncestors(self.allocator, parent.source_path);
        }
        if (!try containsController(self.allocator, parent.source_path, "dmem")) return error.HierarchyNotEnabled;

        try makeDir(parent.other_child_path);
        try makeDir(first.child_path);
        try movePidToChild(self.allocator, first_pid, first.child_path);
        try self.moveInternalParentPids(parent.source_path, first.child_path, parent.other_child_path, first.profile_idx, first_pid);
        try writeFile(self.allocator, parent.source_path, "cgroup.subtree_control", "+dmem");

        parent.prepared = true;
        parent.subtree_dmem_enabled = true;
        try writeLowPath(self.allocator, parent.other_child_path, self.regions, .inactive);
    }

    fn moveInternalParentPids(self: *Manager, source_path: []const u8, protected_child: []const u8, other_child: []const u8, profile_idx: u8, first_pid: u32) !void {
        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            const pids = try readCgroupProcs(self.allocator, source_path);
            defer self.allocator.free(pids);
            if (pids.len == 0) return;

            for (pids) |pid| {
                const target = if (pid == first_pid or self.pidBelongsToProfile(pid, profile_idx)) protected_child else other_child;
                movePidToChild(self.allocator, pid, target) catch {};
            }
        }

        return error.ParentStillPopulated;
    }

    fn pidBelongsToProfile(self: *Manager, pid: u32, profile_idx: u8) bool {
        if (self.pid_records.get(pid)) |record| {
            return record.profile_idx == profile_idx;
        }
        return false;
    }

    fn removeVanishedCgroups(self: *Manager) void {
        var vanished_profiles: std.ArrayList([]const u8) = .empty;
        defer vanished_profiles.deinit(self.allocator);

        var pcg_it = self.profile_cgroups.iterator();
        while (pcg_it.next()) |entry| {
            if (!pathExists(entry.value_ptr.child_path)) {
                vanished_profiles.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (vanished_profiles.items) |key| {
            self.removeProfileRecord(key);
        }

        var vanished_parents: std.ArrayList([]const u8) = .empty;
        defer vanished_parents.deinit(self.allocator);

        var parent_it = self.parent_records.iterator();
        while (parent_it.next()) |entry| {
            if (!pathExists(entry.value_ptr.source_path)) {
                vanished_parents.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (vanished_parents.items) |key| {
            if (self.parent_records.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.other_child_path);
            }
        }
    }

    fn removeProfileRecord(self: *Manager, key: []const u8) void {
        const removed = self.profile_cgroups.fetchRemove(key) orelse return;
        defer {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.source_path);
            self.allocator.free(removed.value.profile_name);
        }

        var to_remove: std.ArrayList(u32) = .empty;
        defer to_remove.deinit(self.allocator);

        var pid_it = self.pid_records.iterator();
        while (pid_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.child_path, removed.value.child_path)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |pid| {
            if (self.pid_records.fetchRemove(pid)) |pid_removed| {
                self.freePidRecord(pid_removed.value);
            }
        }
    }

    fn writeLow(self: *Manager, record: *ProfileCgroupRecord, state: ProtectState) void {
        if (self.availability != .available) {
            record.protected = state == .active;
            record.zeroed = state == .inactive;
            return;
        }

        writeLowPath(self.allocator, record.child_path, self.regions, state) catch |err| {
            const mapped = mapTrackError(err);
            record.last_error = mapped;
            self.noteError(mapped);
            return;
        };
        record.protected = state == .active;
        record.zeroed = state == .inactive;
        record.last_error = null;
    }

    fn noteError(self: *Manager, availability: Availability) void {
        self.last_error = availability;
    }

    fn freePidRecord(self: *Manager, record: PidRecord) void {
        self.allocator.free(record.source_path);
        self.allocator.free(record.child_path);
    }
};

fn readPidCgroupPath(allocator: std.mem.Allocator, pid: u32) ![]const u8 {
    const proc_path = try std.fmt.allocPrint(allocator, "/proc/{d}/cgroup", .{pid});
    defer allocator.free(proc_path);

    const content = try readFileAlloc(allocator, proc_path);
    defer allocator.free(content);

    const relative = try path_mod.parseUnifiedCgroupPath(content);
    return try path_mod.cgroupFsPathFromUnified(allocator, relative);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(ioGlobal(), path, allocator, .limited(max_file_size));
}

fn containsController(allocator: std.mem.Allocator, path: []const u8, controller: []const u8) !bool {
    const controllers_path = try std.fmt.allocPrint(allocator, "{s}/cgroup.controllers", .{path});
    defer allocator.free(controllers_path);
    const bytes = try readFileAlloc(allocator, controllers_path);
    defer allocator.free(bytes);
    return containsToken(bytes, controller);
}

fn containsToken(content: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, content, " \n\r\t");
    while (it.next()) |item| {
        if (std.mem.eql(u8, item, token)) return true;
    }
    return false;
}

fn enableDmemOnSafeAncestors(allocator: std.mem.Allocator, source_path: []const u8) !void {
    if (!std.mem.startsWith(u8, source_path, cgroup_root)) return error.InvalidCgroupPath;
    var offset: usize = cgroup_root.len;
    while (offset < source_path.len) {
        while (offset < source_path.len and source_path[offset] == '/') offset += 1;
        while (offset < source_path.len and source_path[offset] != '/') offset += 1;
        const ancestor = source_path[0..offset];

        if (try containsController(allocator, ancestor, "dmem")) {
            if (std.mem.eql(u8, ancestor, cgroup_root) or try cgroupProcsEmpty(allocator, ancestor)) {
                writeFile(allocator, ancestor, "cgroup.subtree_control", "+dmem") catch {};
            } else {
                return;
            }
        }
    }
}

fn cgroupProcsEmpty(allocator: std.mem.Allocator, path: []const u8) !bool {
    const pids = try readCgroupProcs(allocator, path);
    defer allocator.free(pids);
    return pids.len == 0;
}

fn readCgroupProcs(allocator: std.mem.Allocator, path: []const u8) ![]u32 {
    const procs_path = try std.fmt.allocPrint(allocator, "{s}/cgroup.procs", .{path});
    defer allocator.free(procs_path);
    const bytes = try readFileAlloc(allocator, procs_path);
    defer allocator.free(bytes);

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, bytes, " \n\r\t");
    while (it.next()) |pid_text| {
        const pid = std.fmt.parseUnsigned(u32, pid_text, 10) catch continue;
        try out.append(allocator, pid);
    }
    return try out.toOwnedSlice(allocator);
}

fn makeDir(path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(ioGlobal(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(ioGlobal(), path, .{}) catch return false;
    return true;
}

fn movePidToChild(allocator: std.mem.Allocator, pid: u32, child_path: []const u8) !void {
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_text);
    try writeFile(allocator, child_path, "cgroup.procs", pid_text);
}

fn writeLowPath(allocator: std.mem.Allocator, child_path: []const u8, regions: []const Region, state: ProtectState) !void {
    const payload = try formatLowPayload(allocator, regions, state);
    defer allocator.free(payload);
    try writeFile(allocator, child_path, "dmem.low", payload);
}

fn writeFile(allocator: std.mem.Allocator, dir_path: []const u8, file_name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(path);

    const file = try std.Io.Dir.openFileAbsolute(ioGlobal(), path, .{ .mode = .write_only });
    defer file.close(ioGlobal());
    try file.writeStreamingAll(ioGlobal(), content);
}

fn mapAccessError(err: anyerror, fallback: Availability) Availability {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.FileNotFound, error.NotDir => fallback,
        else => fallback,
    };
}

fn mapReadError(err: anyerror, fallback: Availability) Availability {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.FileNotFound, error.NotDir => fallback,
        else => fallback,
    };
}

fn mapTrackError(err: anyerror) Availability {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.HierarchyNotEnabled => .hierarchy_not_enabled,
        error.FileNotFound, error.NotDir => .hierarchy_not_enabled,
        error.ParentStillPopulated, error.Busy => .cannot_prepare_parent,
        else => .cannot_prepare_parent,
    };
}

test "manager refcounts multiple pids in one profile cgroup and zeroes on final release" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.availability = .no_capacity_file;

    manager.trackPidForTest(7, "Game.exe", 101, "/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe", .active);
    manager.trackPidForTest(7, "Game.exe", 102, "/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe", .active);

    try std.testing.expectEqual(@as(usize, 2), manager.pid_records.count());
    try std.testing.expectEqual(@as(u32, 2), manager.profile_cgroups.get("/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe").?.ref_count);

    manager.releasePid(7, 101);
    try std.testing.expectEqual(@as(u32, 1), manager.profile_cgroups.get("/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe").?.ref_count);
    try std.testing.expect(!manager.profile_cgroups.get("/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe").?.zeroed);

    manager.releasePid(7, 102);
    try std.testing.expectEqual(@as(u32, 0), manager.profile_cgroups.get("/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe").?.ref_count);
    try std.testing.expect(manager.profile_cgroups.get("/sys/fs/cgroup/app.scope/falcond-dmem-p07-Game.exe").?.zeroed);
}

test "runtime errors do not change base availability" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.availability = .available;

    manager.noteError(.permission_denied);

    try std.testing.expectEqual(Availability.available, manager.availability);
    try std.testing.expectEqual(@as(?Availability, .permission_denied), manager.last_error);
}

test "failed parent prep keeps pid ownership record for cleanup" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.availability = .available;

    manager.trackPidForTest(3, "Game.exe", 333, "/definitely/not/a/cgroup/falcond-dmem-p03-Game.exe", .active);

    try std.testing.expectEqual(@as(?u8, 3), if (manager.pid_records.get(333)) |record| record.profile_idx else null);
    try std.testing.expectEqual(@as(usize, 1), manager.profile_cgroups.count());
}

test "moveInternalParentPids propagates cgroup.procs read failure" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectError(error.FileNotFound, manager.moveInternalParentPids(
        "/definitely/not/a/cgroup",
        "/definitely/not/a/cgroup/falcond-dmem-p01-Game.exe",
        "/definitely/not/a/cgroup/falcond-dmem-other",
        1,
        100,
    ));
}
