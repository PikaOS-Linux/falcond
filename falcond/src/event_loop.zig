const std = @import("std");
const otter_utils = @import("otter_utils");
const config_mod = @import("config.zig");

const log = std.log.scoped(.event_loop);
const linux = std.os.linux;
const posix = std.posix;

const Self = @This();

// ── Netlink / Proc Connector constants ──────────────────────────────────────

const NETLINK_CONNECTOR = 11;
const CN_IDX_PROC = 0x1;
const CN_VAL_PROC = 0x1;
const PROC_CN_MCAST_LISTEN = 1;
const PROC_CN_MCAST_IGNORE = 2;
const PROC_EVENT_FORK = 0x00000001;
const PROC_EVENT_EXEC = 0x00000002;
const PROC_EVENT_EXIT = 0x80000000;

// ── Netlink ABI structs ─────────────────────────────────────────────────────

const NlMsgHdr = extern struct {
    nlmsg_len: u32,
    nlmsg_type: u16,
    nlmsg_flags: u16,
    nlmsg_seq: u32,
    nlmsg_pid: u32,
};

const SockaddrNl = extern struct {
    nl_family: u16 = posix.AF.NETLINK,
    nl_pad: u16 = 0,
    nl_pid: u32 = 0,
    nl_groups: u32 = 0,
};

const CbId = extern struct {
    idx: u32,
    val: u32,
};

const CnMsg = extern struct {
    id: CbId,
    seq: u32,
    ack: u32,
    len: u16,
    flags: u16,
};

const ProcEventHeader = extern struct {
    what: u32,
    cpu: u32,
    timestamp_ns: u64,
};

const ExecProcEvent = extern struct {
    process_pid: u32,
    process_tgid: u32,
};

const ExitProcEvent = extern struct {
    process_pid: u32,
    process_tgid: u32,
    exit_code: u32,
    exit_signal: u32,
};

// ── Subscription message layout ─────────────────────────────────────────────

const SubscribeMsg = extern struct {
    nl_hdr: NlMsgHdr,
    cn_msg: CnMsg,
    mode: u32,
};

// ── FdTag + Event ───────────────────────────────────────────────────────────

const FdTag = enum(u32) { signal = 0, inotify = 1, netlink = 2 };

pub const ForkInfo = struct { parent: u32, child: u32 };

pub const Event = union(enum) {
    signal_term: void,
    signal_hup: void,
    config_changed: void,
    proc_fork: ForkInfo,
    proc_exec: u32,
    proc_exit: u32,
    timeout: void,
};

pub const EventList = otter_utils.BoundedArray(Event, 128);

// ── Fields ──────────────────────────────────────────────────────────────────

epoll_fd: posix.fd_t,
signal_fd: posix.fd_t,
watcher: otter_utils.inotify.Watcher,
netlink_fd: ?posix.fd_t,
tracked_pids: ?*std.AutoHashMap(u32, u8) = null,
profile_pid_counts: ?*[@import("profiles.zig").max_profiles]u16 = null,

// ── Init / Deinit ───────────────────────────────────────────────────────────

pub fn init(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    profiles_dir: []const u8,
) !Self {
    const epoll_raw = posix.system.epoll_create1(linux.EPOLL.CLOEXEC);
    if (epoll_raw < 0) return error.EpollCreateFailed;
    const epoll_fd: posix.fd_t = @intCast(epoll_raw);
    errdefer _ = posix.system.close(epoll_fd);

    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.TERM);
    posix.sigaddset(&mask, posix.SIG.HUP);
    posix.sigaddset(&mask, posix.SIG.INT);

    const signal_fd = posix.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC) catch {
        return error.SignalFdFailed;
    };
    errdefer _ = posix.system.close(signal_fd);

    epollAdd(epoll_fd, signal_fd, .signal);

    var watcher = try otter_utils.inotify.Watcher.init(allocator);
    errdefer watcher.deinit();

    _ = watcher.addWatch(config_path, otter_utils.inotify.Watcher.Mask.file_changes) catch |err| {
        log.warn("inotify: cannot watch config {s}: {}", .{ config_path, err });
    };
    _ = watcher.addWatch(profiles_dir, otter_utils.inotify.Watcher.Mask.dir_changes) catch |err| {
        log.warn("inotify: cannot watch profiles dir {s}: {}", .{ profiles_dir, err });
    };
    _ = watcher.addWatch(config_mod.user_profiles_dir, otter_utils.inotify.Watcher.Mask.dir_changes) catch |err| {
        log.warn("inotify: cannot watch user profiles dir: {}", .{err});
    };

    epollAdd(epoll_fd, watcher.getFd(), .inotify);

    const netlink_fd = initNetlink(epoll_fd);

    return .{
        .epoll_fd = epoll_fd,
        .signal_fd = signal_fd,
        .watcher = watcher,
        .netlink_fd = netlink_fd,
    };
}

pub fn deinit(self: *Self) void {
    if (self.netlink_fd) |fd| {
        _ = sendNetlinkControl(fd, PROC_CN_MCAST_IGNORE);
        _ = posix.system.close(fd);
    }
    self.watcher.deinit();
    _ = posix.system.close(self.signal_fd);
    _ = posix.system.close(self.epoll_fd);
    self.* = undefined;
}

// ── Wait ────────────────────────────────────────────────────────────────────

pub fn wait(self: *Self, timeout_ms: u32) EventList {
    var epoll_events: [16]linux.epoll_event = undefined;
    const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));

    const n = posix.system.epoll_wait(self.epoll_fd, &epoll_events, epoll_events.len, timeout);

    var events = EventList{};

    if (n < 0) {
        return events;
    }

    const count: usize = @intCast(n);
    if (count == 0) {
        events.append(.timeout) catch {};
        return events;
    }

    for (epoll_events[0..count]) |ev| {
        const tag: FdTag = switch (ev.data.u32) {
            @intFromEnum(FdTag.signal) => .signal,
            @intFromEnum(FdTag.inotify) => .inotify,
            @intFromEnum(FdTag.netlink) => .netlink,
            else => {
                log.warn("epoll: unknown fd tag {d}", .{ev.data.u32});
                continue;
            },
        };
        switch (tag) {
            .signal => self.drainSignals(&events),
            .inotify => self.drainInotify(&events),
            .netlink => self.drainNetlink(&events),
        }
    }

    return events;
}

// ── Watch management ────────────────────────────────────────────────────────

pub fn updateWatches(
    self: *Self,
    config_path: []const u8,
    profiles_dir: []const u8,
) void {
    self.watcher.removeWatchByPath(config_path);
    self.watcher.removeWatchByPath(profiles_dir);
    self.watcher.removeWatchByPath(config_mod.user_profiles_dir);

    _ = self.watcher.addWatch(config_path, otter_utils.inotify.Watcher.Mask.file_changes) catch |err| {
        log.warn("inotify: cannot re-watch config: {}", .{err});
    };
    _ = self.watcher.addWatch(profiles_dir, otter_utils.inotify.Watcher.Mask.dir_changes) catch |err| {
        log.warn("inotify: cannot re-watch profiles dir: {}", .{err});
    };
    _ = self.watcher.addWatch(config_mod.user_profiles_dir, otter_utils.inotify.Watcher.Mask.dir_changes) catch |err| {
        log.warn("inotify: cannot re-watch user profiles dir: {}", .{err});
    };
}

// ── Private: drain helpers ──────────────────────────────────────────────────

fn drainSignals(self: *Self, events: *EventList) void {
    while (true) {
        var buf: [@sizeOf(linux.signalfd_siginfo)]u8 align(@alignOf(linux.signalfd_siginfo)) = undefined;
        const n = posix.system.read(self.signal_fd, &buf, buf.len);
        if (n < 0 or n != @sizeOf(linux.signalfd_siginfo)) break;
        const info: *const linux.signalfd_siginfo = @ptrCast(&buf);
        const event: ?Event = if (info.signo == @intFromEnum(linux.SIG.TERM) or info.signo == @intFromEnum(linux.SIG.INT))
            .signal_term
        else if (info.signo == @intFromEnum(linux.SIG.HUP))
            .signal_hup
        else
            null;
        if (event) |ev| events.append(ev) catch {};
    }
}

fn drainInotify(self: *Self, events: *EventList) void {
    var saw_change = false;
    while (self.watcher.nextEvent()) |_| {
        saw_change = true;
    }
    if (saw_change) {
        events.append(.config_changed) catch {};
    }
}

fn drainNetlink(self: *Self, events: *EventList) void {
    const fd = self.netlink_fd orelse return;
    var buf: [16384]u8 align(@alignOf(NlMsgHdr)) = undefined;

    while (true) {
        const n = posix.system.read(fd, &buf, buf.len);
        if (n <= 0 or n > buf.len) break;
        const bytes_read: usize = @intCast(n);

        var offset: usize = 0;
        while (offset + @sizeOf(NlMsgHdr) <= bytes_read) {
            const nlh: *const NlMsgHdr = @ptrCast(@alignCast(buf[offset..].ptr));
            if (nlh.nlmsg_len < @sizeOf(NlMsgHdr) or offset + nlh.nlmsg_len > bytes_read) break;

            const what_offset = offset + @sizeOf(NlMsgHdr) + @sizeOf(CnMsg);
            const event_data_offset = what_offset + @sizeOf(ProcEventHeader);

            if (what_offset + @sizeOf(ProcEventHeader) <= bytes_read) {
                const what = std.mem.readInt(u32, buf[what_offset..][0..4], .little);
                self.handleProcEvent(events, what, event_data_offset, bytes_read, &buf);
            }

            offset += (nlh.nlmsg_len + 3) & ~@as(usize, 3);
        }
    }
}

fn handleProcEvent(
    self: *Self,
    events: *EventList,
    what: u32,
    event_data_offset: usize,
    bytes_read: usize,
    buf: []const u8,
) void {
    switch (what) {
        PROC_EVENT_FORK => self.handleForkProcEvent(events, event_data_offset, bytes_read, buf),
        PROC_EVENT_EXEC => self.handleExecProcEvent(events, event_data_offset, bytes_read, buf),
        PROC_EVENT_EXIT => self.handleExitProcEvent(events, event_data_offset, bytes_read, buf),
        else => {},
    }
}

fn handleForkProcEvent(
    self: *Self,
    events: *EventList,
    event_data_offset: usize,
    bytes_read: usize,
    buf: []const u8,
) void {
    const parent_tgid_offset = event_data_offset + @sizeOf(u32);
    const child_tgid_offset = event_data_offset + 3 * @sizeOf(u32);
    if (child_tgid_offset + @sizeOf(u32) > bytes_read) return;

    if (self.tracked_pids) |pids| {
        const parent_tgid = std.mem.readInt(u32, buf[parent_tgid_offset..][0..4], .little);
        const child_tgid = std.mem.readInt(u32, buf[child_tgid_offset..][0..4], .little);
        if (child_tgid == parent_tgid) return;

        if (pids.contains(parent_tgid)) {
            events.append(.{ .proc_fork = .{ .parent = parent_tgid, .child = child_tgid } }) catch {};
        }
    }
}

fn handleExecProcEvent(
    self: *Self,
    events: *EventList,
    event_data_offset: usize,
    bytes_read: usize,
    buf: []const u8,
) void {
    _ = self;
    const tgid_offset = event_data_offset + @sizeOf(u32);
    if (tgid_offset + @sizeOf(u32) > bytes_read) return;

    const tgid = std.mem.readInt(u32, buf[tgid_offset..][0..4], .little);
    if (tgid > 2) {
        events.append(.{ .proc_exec = tgid }) catch {};
    }
}

fn handleExitProcEvent(
    self: *Self,
    events: *EventList,
    event_data_offset: usize,
    bytes_read: usize,
    buf: []const u8,
) void {
    _ = self;
    const tgid_offset = event_data_offset + @sizeOf(u32);
    if (tgid_offset + @sizeOf(u32) > bytes_read) return;

    const pid = std.mem.readInt(u32, buf[event_data_offset..][0..4], .little);
    const tgid = std.mem.readInt(u32, buf[tgid_offset..][0..4], .little);
    if (pid == tgid) {
        events.append(.{ .proc_exit = tgid }) catch {};
    }
}

// ── Private: epoll helper ───────────────────────────────────────────────────

fn epollAdd(epoll_fd: posix.fd_t, fd: posix.fd_t, tag: FdTag) void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .u32 = @intFromEnum(tag) },
    };
    const rc = posix.system.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
    if (rc != 0) {
        log.warn("epoll_ctl add failed for fd {}", .{fd});
    }
}

// ── Private: netlink setup ──────────────────────────────────────────────────

fn initNetlink(epoll_fd: posix.fd_t) ?posix.fd_t {
    const fd_raw = posix.system.socket(posix.AF.NETLINK, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, NETLINK_CONNECTOR);
    if (fd_raw < 0) {
        log.info("netlink proc connector unavailable (socket failed), falling back to poll-only mode", .{});
        return null;
    }
    const fd: posix.fd_t = @intCast(fd_raw);

    var addr = SockaddrNl{
        .nl_groups = CN_IDX_PROC,
        .nl_pid = @intCast(posix.system.getpid()),
    };

    const bind_rc = posix.system.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrNl));
    if (bind_rc != 0) {
        log.info("netlink proc connector unavailable (bind failed), falling back to poll-only mode", .{});
        _ = posix.system.close(fd);
        return null;
    }

    if (!sendNetlinkControl(fd, PROC_CN_MCAST_LISTEN)) {
        log.info("netlink proc connector unavailable (subscribe failed), falling back to poll-only mode", .{});
        _ = posix.system.close(fd);
        return null;
    }

    epollAdd(epoll_fd, fd, .netlink);
    log.info("netlink proc connector active", .{});
    return fd;
}

fn sendNetlinkControl(fd: posix.fd_t, mode: u32) bool {
    var msg = SubscribeMsg{
        .nl_hdr = .{
            .nlmsg_len = @sizeOf(SubscribeMsg),
            .nlmsg_type = @intFromEnum(linux.NetlinkMessageType.DONE),
            .nlmsg_flags = 0,
            .nlmsg_seq = 0,
            .nlmsg_pid = @intCast(posix.system.getpid()),
        },
        .cn_msg = .{
            .id = .{ .idx = CN_IDX_PROC, .val = CN_VAL_PROC },
            .seq = 0,
            .ack = 0,
            .len = @sizeOf(u32),
            .flags = 0,
        },
        .mode = mode,
    };

    const buf: [*]const u8 = @ptrCast(&msg);
    const rc = posix.system.sendto(fd, buf, @sizeOf(SubscribeMsg), 0, null, 0);
    return rc == @sizeOf(SubscribeMsg);
}

test "handleForkProcEvent queues fork event without inheriting child tracking" {
    var tracked = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer tracked.deinit();

    try tracked.put(111, 3);

    var counts = [_]u16{0} ** @import("profiles.zig").max_profiles;
    counts[3] = 1;

    var loop = Self{
        .epoll_fd = undefined,
        .signal_fd = undefined,
        .watcher = undefined,
        .netlink_fd = null,
        .tracked_pids = &tracked,
        .profile_pid_counts = &counts,
    };

    var events = EventList{};
    var buf = [_]u8{0} ** 16;
    std.mem.writeInt(u32, buf[4..8], 111, .little);
    std.mem.writeInt(u32, buf[12..16], 222, .little);

    loop.handleForkProcEvent(&events, 0, buf.len, &buf);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(Event{ .proc_fork = .{ .parent = 111, .child = 222 } }, events.constSlice()[0]);
    try std.testing.expectEqual(@as(?u8, 3), tracked.get(111));
    try std.testing.expectEqual(@as(?u8, null), tracked.get(222));
    try std.testing.expectEqual(@as(u16, 1), counts[3]);
}

test "handleForkProcEvent ignores untracked parent" {
    var tracked = std.AutoHashMap(u32, u8).init(std.testing.allocator);
    defer tracked.deinit();

    var counts = [_]u16{0} ** @import("profiles.zig").max_profiles;
    var loop = Self{
        .epoll_fd = undefined,
        .signal_fd = undefined,
        .watcher = undefined,
        .netlink_fd = null,
        .tracked_pids = &tracked,
        .profile_pid_counts = &counts,
    };

    var events = EventList{};
    var buf = [_]u8{0} ** 16;
    std.mem.writeInt(u32, buf[4..8], 111, .little);
    std.mem.writeInt(u32, buf[12..16], 222, .little);

    loop.handleForkProcEvent(&events, 0, buf.len, &buf);

    try std.testing.expectEqual(@as(usize, 0), events.len);
    try std.testing.expectEqual(@as(?u8, null), tracked.get(222));
}
