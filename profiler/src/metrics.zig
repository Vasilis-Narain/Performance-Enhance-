//* This file is translated into Zig from
//* Casey Muratore's Performance Aware course files.
//* Please see https://computerenhance.com for licensing and more information.
const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const windows = std.os.windows;
const linux = std.os.linux;

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
    var hi: u32 = 0;
    var low: u32 = 0;

    asm volatile (
        \\rdtsc
        : [low] "={eax}" (low),
          [hi] "={edx}" (hi),
    );

    return (@as(u64, hi) << 32) | @as(u64, low);
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
