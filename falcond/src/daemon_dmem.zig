const dmemcg = @import("dmemcg.zig");

pub fn trackPid(self: anytype, profile_idx: u8, pid: u32) void {
    const act = &self.table.activation[profile_idx];
    if (!act.dmem_protect) return;

    if (self.dmem) |*dmem| {
        const state: dmemcg.ProtectState = if (self.active_profile_idx != null and self.active_profile_idx.? == profile_idx)
            .active
        else
            .inactive;
        dmem.trackPid(profile_idx, self.table.names[profile_idx].get(), pid, state);
    }
}

pub fn releasePid(self: anytype, profile_idx: u8, pid: u32) void {
    if (self.dmem) |*dmem| {
        dmem.releasePid(profile_idx, pid);
    }
}
