//* This file is translated into Zig from
//* Casey Muratore's Performance Aware course files.
//* Please see https://computerenhance.com for licensing and more information.
const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const windows = std.os.windows;
const linux = std.os.linux;

const PROCESS_QUERY_INFORMATION: windows.DWORD = 0x0400;
const PROCESS_VM_READ: windows.DWORD = 0x0010;

pub const OsMetrics = struct {
    initialized: bool = false,
    process_handle: windows.HANDLE = undefined,

    pub fn init(self: *@This()) !void {
        self.process_handle = try zigOpenProcess(
            windows.GetCurrentProcessId(),
        );
        self.initialized = true;
    }

    pub fn deinit(self: *@This()) void {
        windows.CloseHandle(self.process_handle);
        self.initialized = false;
    }
};
pub var global_metrics: OsMetrics = .{};

const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: windows.DWORD,
    PageFaultCount: windows.DWORD,
    PeakWorkingSetSize: windows.SIZE_T,
    WorkingSetSize: windows.SIZE_T,
    QuotaPeakPagedPoolUsage: windows.SIZE_T,
    QuotaPagedPoolUsage: windows.SIZE_T,
    QuotaPeakNonPagedPoolUsage: windows.SIZE_T,
    QuotaNonPagedPoolUsage: windows.SIZE_T,
    PagefileUsage: windows.SIZE_T,
    PeakPagefileUsage: windows.SIZE_T,
    PrivateUsage: windows.SIZE_T,
};

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn K32GetProcessMemoryInfo(
    Process: windows.HANDLE,
    ppsmemCounters: *PROCESS_MEMORY_COUNTERS_EX,
    cb: windows.DWORD,
) callconv(.winapi) windows.BOOL;

fn zigOpenProcess(pid: windows.DWORD) !windows.HANDLE {
    return OpenProcess(
        PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
        windows.BOOL.FALSE,
        pid,
    ) orelse switch (windows.GetLastError()) {
        .ACCESS_DENIED => error.AccessDenied,
        .INVALID_PARAMETER => error.NoSuchProcess,
        else => |err| windows.unexpectedError(err),
    };
}

pub fn getOsPageFaultCount() !u64 {
    switch (native_os) {
        .windows => {
            if (!global_metrics.initialized) return error.HandleNotInitialized;

            var memory_counters: PROCESS_MEMORY_COUNTERS_EX = undefined;
            memory_counters.cb = @sizeOf(@TypeOf(memory_counters));

            if (K32GetProcessMemoryInfo(global_metrics.process_handle, &memory_counters, memory_counters.cb) == windows.BOOL.FALSE) {
                return switch (windows.GetLastError()) {
                    .ACCESS_DENIED => error.AccessDenied,
                    .INVALID_HANDLE => error.InvalidHandle,
                    else => |err| windows.unexpectedError(err),
                };
            }

            return memory_counters.PageFaultCount;
        },
        else => @compileError("Not implemented for current OS!"),
    }
}

pub fn getOsTimerFreq() u64 {
    switch (native_os) {
        .windows => {
            var freq: windows.LARGE_INTEGER = undefined;
            _ = windows.ntdll.RtlQueryPerformanceFrequency(&freq);
            return @intCast(freq);
        },
        else => {
            return 1_000_000;
        }
    }
}

pub fn readOsTimer() u64 {
    switch (native_os) {
        .windows => {
            var value: windows.LARGE_INTEGER = undefined;
            _ = windows.ntdll.RtlQueryPerformanceCounter(&value);
            return @intCast(value);
        },
        .linux => {
            var value: linux.timespec = undefined;
            _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &value);

            const result = (@as(u64, @intCast(value.sec)) * 1_000_000_000) + @as(u64, @intCast(value.nsec));
            return result;
        },
        else => @compileError("Unsupported OS"),
    }
}

/// Simple rdtsc asm call (should be equivalent to rdtsc() in intrinsic.h)
pub inline fn readCpuTimer() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            var ret: u64 = undefined;
            asm volatile (
                \\rdtsc
                \\shlq $32, %rdx
                \\orq  %rdx, %rax
                : [ret] "={rax}" (ret)
                :
                : .{ .rdx = true });
            return ret;
        },
        .aarch64 => {
            var ret: u64 = undefined;
            asm volatile (
                \\mrs %[ret], cntvct_el0
                : [ret] "=r" (ret),
            );
            return ret;
        },
        else => @compileError("Unsupported CPU architecture for cycle counting"),
    }
}

pub fn readCpuTimerFreq() u64 {
    // 8 milliseconds seems to be the lowest amount to be within 1_000_000 of the number found
    // with 1000 milliseconds wait time. However, I'll leave it at 100 since that's what Casey used
    // Surely, there is a reason.
    const milliseconds_to_wait: u64 = 100;
    const os_freq = getOsTimerFreq();
    const cpu_start = readCpuTimer();
    const os_start = readOsTimer();
    var os_end: u64 = 0;
    var os_elapsed: u64 = 0;
    const os_wait_time = os_freq * milliseconds_to_wait / 1000;

    while (os_elapsed < os_wait_time) {
        os_end = readOsTimer();
        os_elapsed = os_end - os_start;
    }

    const cpu_end = readCpuTimer();
    const cpu_elapsed = cpu_end - cpu_start;
    return if (os_elapsed > 0) os_freq * cpu_elapsed / os_elapsed else 0;
}

test "read cpu timer" {
    const cpu_freq = readCpuTimerFreq();
    // For obvious reasons this test fails on different machines
    try std.testing.expectApproxEqAbs(3_071_999_436, @as(f64, @floatFromInt(cpu_freq)), 1_000_000);
}

test "metrics os timers" {
    const os_freq = getOsTimerFreq();

    const os_start = readOsTimer();
    var os_end: u64 = 0;
    var os_elapsed: u64 = 0;

    while (os_elapsed < os_freq) {
        os_end = readOsTimer();
        os_elapsed = os_end - os_start;
    }
    try std.testing.expect(10_000_000 == os_elapsed);
}

test "metrics cpu timer" {
    const os_freq = getOsTimerFreq();

    const cpu_start = readCpuTimer();
    const os_start = readOsTimer();
    var os_end: u64 = 0;
    var os_elapsed: u64 = 0;

    while (os_elapsed < os_freq) {
        os_end = readOsTimer();
        os_elapsed = os_end - os_start;
    }

    const cpu_end = readCpuTimer();
    const cpu_elapsed = cpu_end - cpu_start;

    // For obvious reasons this test fails on different machines
    try std.testing.expectApproxEqAbs(3_071_999_436, @as(f64, @floatFromInt(cpu_elapsed)), 1_000_000);
}
