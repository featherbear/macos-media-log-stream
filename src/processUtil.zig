// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master

const c = @cImport({
    @cInclude("libproc.h");
});
const std = @import("std");

fn proc_pidinfo(pid: c.pid_t) c.struct_proc_bsdshortinfo {
    var pbi: c.struct_proc_bsdshortinfo = undefined;
    const result = c.proc_pidinfo(pid, c.PROC_PIDT_SHORTBSDINFO, 0, &pbi, c.PROC_PIDT_SHORTBSDINFO_SIZE);
    _ = result;

    return pbi;
}

pub fn getpid() c.pid_t {
    // Wait a second...
    // return c.getpid();

    const result = asm volatile ("svc #0x80"
        : [ret] "={x0}" (-> c.pid_t),
        : [syscallNo] "{x16}" (20),
        : "x0", "x16"
    );
    return @intCast(result);
}

pub fn getppid() c.pid_t {
    // return c.getppid();

    const result = asm volatile ("svc #0x80"
        : [ret] "={x0}" (-> c.pid_t),
        : [syscallNo] "{x16}" (39),
        : "x0", "x16"
    );
    return @intCast(result);
}

pub fn getppid_of_pid(pid: c.pid_t) c.pid_t {
    return @intCast(proc_pidinfo(pid).pbsi_ppid);
}

pub fn image_path_of_pid(pid: c.pid_t) []u8 {
    var s: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    const r = @as(usize, @intCast(c.proc_pidpath(pid, &s, c.PROC_PIDPATHINFO_MAXSIZE)));
    return s[0..r];
}

pub fn temp_image_name_of_pid(pid: c.pid_t) []u8 {
    // this one kinda breaks when running zig run...

    // COMM length??
    const idk = 32;

    var s: [idk]u8 = undefined;
    const r = @as(usize, @intCast(c.proc_name(pid, &s, idk)));
    return s[0..r];
}

pub fn temp_cwd_of_pid(pid: c.pid_t) []u8 {
    var t: c.struct_proc_vnodepathinfo = undefined;
    const r = c.proc_pidinfo(pid, c.PROC_PIDVNODEPATHINFO, 0, &t, c.PROC_PIDVNODEPATHINFO_SIZE);

    if (r == 0) {
        return "";
    }

    // pvi_cdir current
    // pvi_rdir root
    return t.pvi_cdir.vip_path[0..std.mem.indexOf(u8, &t.pvi_cdir.vip_path, "\x00").?];
}

pub fn temp_tracePID(pid: c.pid_t) void {
    var _pid = pid;
    while (_pid != 0) {
        const ppid = getppid_of_pid(_pid);
        std.debug.print("PID: {d} | libproc PPID: {d}\n", .{ _pid, ppid });

        std.debug.print("Path: {s}\n", .{image_path_of_pid(_pid)});
        std.debug.print("CWD: {s}\n", .{temp_cwd_of_pid(_pid)});
        _pid = ppid;

        std.debug.print("\n", .{});
    }
}
