//* This file is translated into Zig from
//* Casey Muratore's Performance Aware course files.
//* Please see https://computerenhance.com for licensing and more information.
const std = @import("std");
const c = @import("c");
const target_os = @import("builtin").target.os.tag;

pub fn getOsTimerFreq() u64 {
    switch (target_os) {
        .windows => {
            var freq: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceFrequency(&freq);
            return @intCast(freq.QuadPart);
        },
        else => {
            return 1000000;
        }
    }
}

pub fn readOsTimer() u64 {
    switch (target_os) {
        .windows => {
            var value: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceCounter(&value);
            return @intCast(value.QuadPart);
        },
        else => {
            var value: c.timeval = undefined;
            _ = c.gettimeofday(&value, 0);

            const result: u64 = getOsTimerFreq() * @as(u64, @intCast(value.tv_sec)) + @as(u64, @intCast(value.tv_usec));
            return result;
        }
    }
}

/// Function mimicking __rdtsc() functionality from intrinsic.h
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

test "metrics os timers" {
    const os_freq = getOsTimerFreq();

    const os_start = readOsTimer();
    var os_end: u64 = 0;
    var os_elapsed: u64 = 0;

    while (os_elapsed < os_freq) {
        os_end = readOsTimer();
        os_elapsed = os_end - os_start;
    }
    try std.testing.expect(10000000 == os_elapsed);
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
    try std.testing.expectApproxEqAbs(3071999436, @as(f64, @floatFromInt(cpu_elapsed)), 10000000);
}
