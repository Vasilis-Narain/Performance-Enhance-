//! CLI File
//! CLI level API:
//!
//! * `-generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]`
//! * `-process [path to .json] [path to .f64]
const std = @import("std");
const Io = std.Io;

const Haversine = @import("haversine");
const Profiler = @import("profiler");
const metrics = Profiler.metrics;
const profiler = Profiler.profiler;

pub fn main(init: std.process.Init) !void {

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Initialise global (mutable) instance
    const pf = Profiler.profiler_instance;
    pf.init(arena);

    const args = try init.minimal.args.toSlice(arena);
    var opts: Opts = parseArgsCli(arena, args) catch return;

    // In order to do I/O operations need an `Io` instance.
    // Note(vasilis): this is using the platform default IO implementation
    const io = init.io;

    // This is how you print "Hello World" kids
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    switch (opts.call_type) {
        .generate => {
            const method: GenMethod = if (opts.uniform) .uniform else .cluster;
            try stdout_writer.print(
                \\Method: {s}
                \\seed: {d}
                \\n: {d}
                \\
            , .{ @tagName(method), opts.seed, opts.n });

            var file_name_buf: [256]u8 = undefined;

            // Init json output
            const out_file_name = try buildOutFileName(&file_name_buf, method, .json, opts.n);
            var out_file = try Io.Dir.cwd().createFile(io, out_file_name, .{});
            defer out_file.close(io);
            var fileout_buffer: [1024]u8 = undefined;
            var fileout_writer = out_file.writer(io, &fileout_buffer);
            const file_writer = &fileout_writer.interface;

            // Init byte output
            const byte_file_name = try buildOutFileName(&file_name_buf, method, .f64, opts.n);
            var byte_file = try Io.Dir.cwd().createFile(io, byte_file_name, .{});
            defer byte_file.close(io);
            var byteout_buffer: [1024]u8 = undefined;
            var byteout_writer = byte_file.writer(io, &byteout_buffer);
            const byte_writer = &byteout_writer.interface;

            try Haversine.generateInput(byte_writer, file_writer, &opts);
            try stdout_writer.print("\nExpected sum: {d:.8}\n", .{opts.statistic});
            try file_writer.flush();
            try byte_writer.flush();
        },
        .process => {
            const untracked_misc: *profiler.trace = try .init(pf, "untracked_misc", @src());
            defer untracked_misc.deinit();
            // Not bothering with catching errors cause realistically if we can't open the files we should crash.

            // Init json file reader
            var json_file = try Io.Dir.cwd().openFile(io, opts.json_file_name, .{ .mode = .read_only });
            defer json_file.close(io);
            const json_size = (try json_file.stat(io)).size;
            const json_buffer = try arena.alloc(u8, json_size);
            defer arena.free(json_buffer);
            var json_file_reader = json_file.reader(io, json_buffer);
            const json_reader = &json_file_reader.interface;

            const json_read_trace: *profiler.trace = try .init(pf, "json_read_trace", @src());
            try json_reader.fill(json_size);
            json_read_trace.deinit();

            // Init byte file reader
            var byte_file = try Io.Dir.cwd().openFile(io, opts.byte_file_name, .{ .mode = .read_only });
            defer byte_file.close(io);
            const byte_file_size = (try byte_file.stat(io)).size;
            var byte_buffer: [8]u8 = undefined;
            var byte_file_reader = byte_file.reader(io, &byte_buffer);
            const byte_reader = &byte_file_reader.interface;

            // Only need last 8 bytes (an f64) for the reference sum
            try byte_file_reader.seekTo(byte_file_size - 8);
            const last8 = try byte_reader.take(8);
            const reference_sum: f64 = @bitCast(std.mem.readInt(u64, last8[0..8], .native)); // Handles endianness.

            const points: Haversine.Points = try Haversine.parseJson(arena, json_reader);
            const haversine_sum = points.total / @as(f64, @floatFromInt(points.count));

            try stdout_writer.print(
                \\
                \\Input size: {d}
                \\Pair count: {d}
                \\
                \\Haversine sum average: {d}
                \\
                \\Validation:
                \\Reference sum: {d}
                \\Difference: {d}
                \\
                \\
            ,
                .{
                    json_size,
                    points.count,
                    haversine_sum,
                    reference_sum,
                    haversine_sum - reference_sum,
                },
            );
        },
    }

    // FLUSHING!
    try pf.deinit(stdout_writer);
    try stdout_writer.flush();
}

fn percentageWorkDone(work_elapsed: u64, process_elapsed: u64) f64 {
    return (@as(f64, @floatFromInt(work_elapsed)) / @as(f64, @floatFromInt(process_elapsed))) * 100;
}

const CallType = enum {
    generate,
    process,
};

const OutType = enum {
    json,
    f64,
};

const GenMethod = enum {
    cluster,
    uniform,
};

const Opts = struct {
    call_type: CallType = undefined,
    uniform: bool = undefined,
    seed: u32 = undefined,
    n: u32 = undefined,
    statistic: f64 = 0,
    json_file_name: []const u8 = undefined,
    byte_file_name: []const u8 = undefined,
};

/// Parses CLI args and returns Opts struct.
fn parseArgsCli(allocator: std.mem.Allocator, args: []const []const u8) !Opts {
    var opts: Opts = .{};
    if (args.len < 2) {
        std.log.err(
            \\Usage:
            \\  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]" 
            \\  -process [path to json] [path to .f64]
            \\ 
        ,
            .{},
        );
        return error.InvalidUsage;
    }

    if (std.mem.eql(u8, args[1], "-generate")) {
        if (args.len != 5) {
            std.log.err("Usage:\n  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
            return error.InvalidUsage;
        } else {
            opts.call_type = .generate;
            opts.uniform = blk: {
                if (std.mem.eql(u8, args[2], "uniform")) {
                    break :blk true;
                } else if (std.mem.eql(u8, args[2], "cluster")) {
                    break :blk false;
                } else {
                    std.log.err("Usage:\n  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
                    return error.InvalidUsage;
                }
            };
            opts.seed = stringToInt(u32, args[3]) catch |err| switch (err) {
                error.InvalidDigit => {
                    std.log.err("seed arg must be numeric and positive! Found {s}\n", .{args[3]});
                    return err;
                },
                error.Overflow => {
                    std.log.err("seed value too large!\n", .{});
                    return err;
                },
            };
            opts.n = stringToInt(u32, args[4]) catch |err| switch (err) {
                error.InvalidDigit => {
                    std.log.err("number of coordinate pairs arg must be numeric and positive! Found {s}\n", .{args[4]});
                    return err;
                },
                error.Overflow => {
                    std.log.err("number of coordinate pairs too large!\n", .{});
                    return err;
                },
            };
        }
    } else if (std.mem.eql(u8, args[1], "-process")) {
        if (args.len < 3) {
            std.log.err("Usage:\n  -process [path to json] [path to .f64]\n", .{});
            return error.InvalidUsage;
        } else {
            opts.call_type = .process;
            opts.json_file_name = try allocator.dupe(u8, args[2]);
            opts.byte_file_name = try allocator.dupe(u8, args[3]);
        }
    } else {
        std.log.err(
            \\Usage:
            \\  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]" 
            \\  -process [path to json] [path to .f64]
            \\ 
        ,
            .{},
        );
        return error.InvalidUsage;
    }
    return opts;
}

/// Builds Output file name depending on options
fn buildOutFileName(buf: []u8, method: GenMethod, fileType: OutType, n: u32) ![]const u8 {
    return try std.fmt.bufPrint(
        buf,
        "input/{s}_{d}.{s}",
        .{ @tagName(method), n, @tagName(fileType) },
    );
}

/// Can only return unsigned types. Or else...
fn stringToInt(comptime T: type, str: []const u8) !T {
    comptime {
        switch (@typeInfo(T)) {
            .int => |info| {
                if (info.signedness != .unsigned or info.bits < 8) {
                    @compileError("stringToInt() can only return unsigned integer types (at least u8), found" ++ @tagName(@typeInfo(T).int.signedness));
                }
            },
            else => @compileError("stringToInt() can only return unsigned integer types (at least u8), found" ++ @typeName(T)),
        }
    }

    // Note(vasilis) these are comptime
    const max_by_10: T = std.math.maxInt(T) / 10;
    const max_mod_10: T = std.math.maxInt(T) % 10;

    var result: T = 0;
    for (str) |char| {
        if (char < '0' or char > '9') {
            return error.InvalidDigit;
        }
        const digit = char - '0';

        if ((result > max_by_10) or (result == max_by_10 and digit > max_mod_10)) {
            return error.Overflow;
        }

        result = result * 10 + digit;
    }
    return result;
}

test "string to int" {
    const str1 = "179a8";
    try std.testing.expectEqual(error.InvalidDigit, stringToInt(u32, str1[0..]));
    const str2 = "17998";
    try std.testing.expectEqual(17998, stringToInt(u32, str2[0..]));
    const str3 = "179989877283746986109238";
    try std.testing.expectEqual(error.Overflow, stringToInt(u32, str3[0..]));
}
