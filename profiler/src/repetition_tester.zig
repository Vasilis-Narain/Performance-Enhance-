//* File containing repetition tester.
//* Basically just runs a given function many times converging to a min runtime.
//* Challenge here is making it (somewhat) reusable..
const std = @import("std");
const metrics = @import("metrics.zig");

const TestResults = struct {
    minTsc: u64 = std.math.maxInt(u64),
    maxTsc: u64 = 0,
    totalCount: u64 = 0,
    totalTsc: u64 = 0,

    total_page_faults: u64 = 0,
    max_page_faults: u64 = 0,
    min_page_faults: u64 = 0,
};

const Tester = struct {
    cpu_freq: u64,
    elapsed_tsc: u64 = 0,
    page_faults: u64 = 0,

    fn init() @This() {
        return .{
            .cpu_freq = metrics.readCpuTimerFreq(),
        };
    }

    fn beginTime(self: *Tester) !void {
        self.elapsed_tsc = metrics.readCpuTimer();
        self.page_faults = try metrics.getOsPageFaultCount();
    }

    fn endTime(self: *Tester) !void {
        self.elapsed_tsc = metrics.readCpuTimer() - self.elapsed_tsc;
        self.page_faults = try metrics.getOsPageFaultCount() - self.page_faults;
    }
};

pub fn repetitionTester(writer: *std.Io.Writer, comptime f: anytype, args: anytype, bytes_processed: u64, seconds_to_try: u64) !TestResults {
    var tester: Tester = .init();
    var results: TestResults = .{};

    const tsc_to_try = seconds_to_try * tester.cpu_freq;
    var tsc_no_min_found: u64 = 0;
    var local = args;

    while (true) {
        try tester.beginTime();

        std.mem.doNotOptimizeAway(&local);
        const result = @call(.auto, f, local);
        switch (@typeInfo(@TypeOf(result))) {
            .error_union => std.mem.doNotOptimizeAway(try result),
            .void => {},
            else => std.mem.doNotOptimizeAway(result),
        }

        try tester.endTime();

        results.totalCount += 1;
        results.totalTsc += tester.elapsed_tsc;
        results.total_page_faults += tester.page_faults;
        tsc_no_min_found += tester.elapsed_tsc;

        if (tester.elapsed_tsc < results.minTsc) {
            tsc_no_min_found = 0;
            results.minTsc = tester.elapsed_tsc;
            results.min_page_faults = tester.page_faults;
            try writer.print("min: {d} ({d:.4}ms) @ {d:.2}GiB/s                                   \r", .{
                results.minTsc, calcMilliSeconds(results.minTsc, tester.cpu_freq), calcGiBs(results.minTsc, tester.cpu_freq, bytes_processed),
            });
            try writer.flush();
        }

        if (tester.elapsed_tsc > results.maxTsc) {
            results.maxTsc = tester.elapsed_tsc;
            results.max_page_faults = tester.page_faults;
        }

        if (tsc_no_min_found > tsc_to_try) break;
    }

    const avg_tsc: u64 = results.totalTsc / results.totalCount;
    const avg_page_faults: u64 = results.total_page_faults / results.totalCount;
    const min_kb_per_fault = calcKibPerPageFault(bytes_processed, results.min_page_faults);
    const max_kb_per_fault = calcKibPerPageFault(bytes_processed, results.max_page_faults);
    const avg_kb_per_fault = calcKibPerPageFault(bytes_processed, avg_page_faults);

    try writer.print("                                                                                     \r", .{});
    try writer.print(
        \\  Results:
        \\   max: {d} ({d:.4}ms) @ {d:.2}GiB/s PF: {d} ({d:.2}KiB/fault),
        \\   min: {d} ({d:.4}ms) @ {d:.2}GiB/s PF: {d} ({d:.2}KiB/fault),
        \\   avg: {d} ({d:.4}ms) @ {d:.2}GiB/s PF: {d} ({d:.2}KiB/fault),
        \\  total iterations: {d}
        \\
    ,
        .{
            results.maxTsc,     calcMilliSeconds(results.maxTsc, tester.cpu_freq), calcGiBs(results.maxTsc, tester.cpu_freq, bytes_processed), results.max_page_faults, max_kb_per_fault,
            results.minTsc,     calcMilliSeconds(results.minTsc, tester.cpu_freq), calcGiBs(results.minTsc, tester.cpu_freq, bytes_processed), results.min_page_faults, min_kb_per_fault,
            avg_tsc,            calcMilliSeconds(avg_tsc, tester.cpu_freq),        calcGiBs(avg_tsc, tester.cpu_freq, bytes_processed),        avg_page_faults,         avg_kb_per_fault,
            results.totalCount,
        },
    );

    return results;
}

fn calcKibPerPageFault(bytes: u64, faults: u64) f64 {
    const kilobyte: f64 = 1024;
    const fbytes: f64 = @floatFromInt(bytes);
    const ffaults: f64 = @floatFromInt(faults);
    const bytes_per_fault = fbytes / ffaults;
    const kilobytes_per_fault = bytes_per_fault / kilobyte;
    return kilobytes_per_fault;
}

fn calcMilliSeconds(tsc: u64, cpu_freq: u64) f64 {
    return (@as(f64, @floatFromInt(tsc)) / @as(f64, @floatFromInt(cpu_freq))) * 1000;
}

fn calcGiBs(tsc: u64, cpu_freq: u64, bytes: u64) f64 {
    const megabyte: f64 = 1024 * 1024;
    const gigabyte: f64 = 1024 * megabyte;
    const seconds: f64 = @as(f64, @floatFromInt(tsc)) / @as(f64, @floatFromInt(cpu_freq));
    const bytes_per_second: f64 = @as(f64, @floatFromInt(bytes)) / seconds;
    const gigabytes_per_second = bytes_per_second / gigabyte;
    return gigabytes_per_second;
}

fn readWholeFile(reader: *std.Io.File.Reader, size: u64) !void {
    reader.interface.tossBuffered();
    try reader.seekTo(0);
    try reader.interface.fill(size);
}

fn readWholeFileFresh(io: std.Io, file: *std.Io.File, alloc: std.mem.Allocator, size: u64) !void {
    const buf = try alloc.alloc(u8, size);
    defer alloc.free(buf);
    var fr = file.reader(io, buf);
    try fr.interface.fill(size);
}

fn writeToBufferOnly(buffer: []u8) void {
    for (buffer, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }
}

fn writeToBufferOnlyBackwards(buffer: []u8) void {
    var i = buffer.len;
    while (i > 0) {
        i -= 1;
        buffer[i] = @truncate(i);
    }
}

fn writeToBufferOncePerPage(buffer: []u8) void {
    var i: usize = 0;
    while (i < buffer.len) : (i += 4096) {
        buffer[i] = @truncate(i);
    }
}

test "read big file fresh (like haversine does)" {
    try metrics.global_metrics.init();
    defer metrics.global_metrics.deinit();
    const io = std.testing.io;
    const arena = std.testing.allocator;

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer_backing: std.Io.File.Writer = .init(.stdout(), io, &stdout_buff);
    const stdout_writer = &stdout_writer_backing.interface;

    var json_file = try std.Io.Dir.cwd().openFile(
        io,
        "../haversine_processor/input/cluster_10000000.json",
        .{ .mode = .read_only },
    );
    defer json_file.close(io);
    const size = (try json_file.stat(io)).size;

    // The thing:
    try stdout_writer.writeAll("\n--- discarding buffer per iteration ----\n");
    _ = try repetitionTester(stdout_writer, readWholeFileFresh, .{ io, &json_file, arena, size }, size, 10);

    try stdout_writer.flush();
}

test "read big file reusing buffer" {
    try metrics.global_metrics.init();
    defer metrics.global_metrics.deinit();
    const io = std.testing.io;
    const arena = std.testing.allocator;

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer_backing: std.Io.File.Writer = .init(.stdout(), io, &stdout_buff);
    const stdout_writer = &stdout_writer_backing.interface;

    var json_file = try std.Io.Dir.cwd().openFile(
        io,
        "../haversine_processor/input/cluster_10000000.json",
        .{ .mode = .read_only },
    );
    defer json_file.close(io);
    const json_size = (try json_file.stat(io)).size;
    const json_buffer = try arena.alloc(u8, json_size);
    defer arena.free(json_buffer);
    var json_reader = json_file.reader(io, json_buffer);

    // The thing:
    try stdout_writer.writeAll("\n--- not discarding buffer per iteration ----\n");
    _ = try repetitionTester(stdout_writer, readWholeFile, .{ &json_reader, json_size }, json_size, 10);

    try stdout_writer.flush();
}

test "just allocate, no file" {
    try metrics.global_metrics.init();
    defer metrics.global_metrics.deinit();
    const io = std.testing.io;
    const arena = std.heap.page_allocator;

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer_backing: std.Io.File.Writer = .init(.stdout(), io, &stdout_buff);
    const stdout_writer = &stdout_writer_backing.interface;

    const buff_size: u64 = 1 << 30;
    const testing_buff = try arena.alloc(u8, buff_size);
    defer arena.free(testing_buff);

    try stdout_writer.print("\n--- {s} ---\n", .{@src().fn_name});
    _ = try repetitionTester(stdout_writer, writeToBufferOnly, .{testing_buff}, buff_size, 10);

    try stdout_writer.flush();
}

test "just allocate, no file, backwards" {
    try metrics.global_metrics.init();
    defer metrics.global_metrics.deinit();
    const io = std.testing.io;
    const arena = std.heap.page_allocator;

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer_backing: std.Io.File.Writer = .init(.stdout(), io, &stdout_buff);
    const stdout_writer = &stdout_writer_backing.interface;

    const buff_size: u64 = 1 << 30;
    const testing_buff = try arena.alloc(u8, buff_size);
    defer arena.free(testing_buff);

    try stdout_writer.print("\n--- {s} ---\n", .{@src().fn_name});
    _ = try repetitionTester(stdout_writer, writeToBufferOnlyBackwards, .{testing_buff}, buff_size, 10);

    try stdout_writer.flush();
}

test "just allocate, no file, write once per page" {
    try metrics.global_metrics.init();
    defer metrics.global_metrics.deinit();
    const io = std.testing.io;
    const arena = std.heap.page_allocator;

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer_backing: std.Io.File.Writer = .init(.stdout(), io, &stdout_buff);
    const stdout_writer = &stdout_writer_backing.interface;

    const buff_size: u64 = 1 << 30;
    const testing_buff = try arena.alloc(u8, buff_size);
    defer arena.free(testing_buff);

    try stdout_writer.print("\n--- {s} ---\n", .{@src().fn_name});
    _ = try repetitionTester(stdout_writer, writeToBufferOncePerPage, .{testing_buff}, buff_size, 10);

    try stdout_writer.flush();
}
