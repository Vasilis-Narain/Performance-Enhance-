//* This file is just for testing purposes.
const std = @import("std");
const Io = std.Io;

const Profiler = @import("profiler");
const metrics = Profiler.metrics;
const Trace = Profiler.Trace;

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // .deinit isn't actually needed here since it runs for full program time
    var pf = Profiler.profiler_instance_ptr;
    pf.init(arena);
    defer pf.deinit();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    const milliseconds_to_wait: u64 = if (args.len == 2) try std.fmt.parseInt(u64, args[1], 10) else 1000;

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    const stdout_setup_trace: *Trace = try .init(pf, "stdout_setup_trace", @src());
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    stdout_setup_trace.deinit();

    {
        const main_loop_trace: *Trace = try .init(pf, "main_loop_trace", @src());
        defer main_loop_trace.deinit();
        try stdout_writer.print("CPU Frequency Estimation:\n", .{});
        const os_freq = metrics.getOsTimerFreq();
        try stdout_writer.print("    OS Freq: {d} (reported)\n", .{os_freq});

        const cpu_start = metrics.readCpuTimer();
        const os_start = metrics.readOsTimer();
        var os_end: u64 = 0;
        var os_elapsed: u64 = 0;
        const os_wait_time = os_freq * milliseconds_to_wait / 1000;

        {
            const inner_loop_trace: *Trace = try .init(pf, "inner_loop_trace", @src());
            defer inner_loop_trace.deinit();
            while (os_elapsed < os_wait_time) {
                os_end = metrics.readOsTimer();
                os_elapsed = os_end - os_start;
            }
        }

        const cpu_end = metrics.readCpuTimer();
        const cpu_elapsed = cpu_end - cpu_start;
        const cpu_freq = if (os_elapsed > 0) os_freq * cpu_elapsed / os_elapsed else 0;

        {
            const print_trace: *Trace = try .init(pf, "print_trace", @src());
            defer print_trace.deinit();

            try stdout_writer.print("    OS Timer: {d} -> {d} = {d} elapsed\n", .{ os_start, os_end, os_elapsed });
            try stdout_writer.print("  OS Seconds: {d:.4}\n", .{@as(f64, @floatFromInt(os_elapsed)) / @as(f64, @floatFromInt(os_freq))});

            try stdout_writer.print("    CPU Timer: {d} -> {d} = {d} elapsed\n", .{ cpu_start, cpu_end, cpu_elapsed });
            try stdout_writer.print("  CPU Freq: {d} (guessed)\n", .{cpu_freq});

            try stdout_writer.print("Now trying api function for same functionality... \n", .{});
            const api_cpu_freq = metrics.readCpuTimerFreq();
            try stdout_writer.print("  CPU Freq: {d} (guessed)\n", .{api_cpu_freq});
        }
    }

    try pf.print(stdout_writer);
    try stdout_writer.flush(); // Don't forget to flush!
}
