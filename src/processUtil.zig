// https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master

const c = @cImport({
    // @compileError("You need to link with libproc on macOS");
    @cInclude("libproc.h");
});

fn proc_pidinfo(pid: c.pid_t) c.struct_proc_bsdshortinfo {
    var pbi: c.struct_proc_bsdshortinfo = undefined;
    const result = c.proc_pidinfo(pid, c.PROC_PIDT_SHORTBSDINFO, 0, &pbi, c.PROC_PIDT_SHORTBSDINFO_SIZE);
    _ = result;

    return pbi;
}

pub fn getpid() c.pid_t {
    const result = asm volatile ("svc #0x80"
        :
        // Outputs
          [ret] "={x0}" (-> c.pid_t),
        :
        // Inputs
          [syscallNo] "{x16}" (20),
        :
        // clobbers
        "x0", "x16"
    );
    return @intCast(result);
}

pub fn getppid() c.pid_t {
    const result = asm volatile ("svc #0x80"
        :
        // Outputs
          [ret] "={x0}" (-> c.pid_t),
        :
        // Inputs
          [syscallNo] "{x16}" (39),
        :
        // clobbers
        "x0", "x16"
    );

    return @intCast(result);
}

pub fn getppid_of_pid(pid: c.pid_t) c.pid_t {
    return @intCast(proc_pidinfo(pid).pbsi_ppid);
}
