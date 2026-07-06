///! CLI File
const std = @import("std");
const Io = std.Io;

const Haversine = @import("haversine");

/// CLI level API:
///     `-generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]`
pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const opts: Opts = parseArgsCli(args) catch return;

    // In order to do I/O operations need an `Io` instance.
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

            // Init json output
            var fileNameBuf: [256]u8 = undefined;
            const outFileName = try buildOutFileName(&fileNameBuf, method, .json, opts.n);
            var outFile = try Io.Dir.cwd().createFile(io, outFileName, .{});
            defer outFile.close(io);
            var fileout_buffer: [1024]u8 = undefined;
            var fileout_writer = outFile.writer(io, &fileout_buffer);
            const file_writer = &fileout_writer.interface;

            // Init byte output
            const byteFileName = try buildOutFileName(&fileNameBuf, method, .f64, opts.n);
            var byteFile = try Io.Dir.cwd().createFile(io, byteFileName, .{});
            defer byteFile.close(io);
            var byteout_buffer: [1024]u8 = undefined;
            var byteout_writer = byteFile.writer(io, &byteout_buffer);
            const byte_writer = &byteout_writer.interface;

            var average: f64 = 0;
            try Haversine.generateInput(byte_writer, file_writer, opts.uniform, opts.seed, opts.n, &average);
            try stdout_writer.print("\nExpected sum: {d:.8}\n", .{average});
            try file_writer.flush();
            try byte_writer.flush();
        },
        .process => {},
    }

    // FLUSHING!
    try stdout_writer.flush(); // Don't forget to flush!
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
    uniform: bool = undefined,
    call_type: CallType = undefined,
    seed: u32 = undefined,
    n: u32 = undefined,
};

/// Parses CLI args and returns Opts struct.
fn parseArgsCli(args: []const []const u8) !Opts {
    var opts: Opts = .{};
    if (args.len < 2) {
        std.debug.print(
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
            std.debug.print("Usage:\n  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
            return error.InvalidUsage;
        } else {
            opts.call_type = .generate;
            opts.uniform = blk: {
                if (std.mem.eql(u8, args[2], "uniform")) {
                    break :blk true;
                } else if (std.mem.eql(u8, args[2], "cluster")) {
                    break :blk false;
                } else {
                    std.debug.print("Usage:\n  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
                    return error.InvalidUsage;
                }
            };
            opts.seed = string_to_int(u32, args[3]) catch |err| switch (err) {
                error.InvalidDigit => {
                    std.debug.print("seed arg must be numeric and positive! Found {s}\n", .{args[3]});
                    return err;
                },
                error.Overflow => {
                    std.debug.print("seed value too large!\n", .{});
                    return err;
                },
            };
            opts.n = string_to_int(u32, args[4]) catch |err| switch (err) {
                error.InvalidDigit => {
                    std.debug.print("number of coordinate pairs arg must be numeric and positive! Found {s}\n", .{args[4]});
                    return err;
                },
                error.Overflow => {
                    std.debug.print("number of coordinate pairs too large!\n", .{});
                    return err;
                },
            };
        }
    } else if (std.mem.eql(u8, args[1], "-process")) {
        if (args.len < 3) {
            std.debug.print("Usage:\n  -process [path to json] [path to .f64]\n", .{});
            return error.InvalidUsage;
        } else {
            opts.call_type = .process;
        }
    } else {
        std.debug.print(
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
fn string_to_int(comptime return_T: type, str: []const u8) !return_T {
    comptime {
        switch (@typeInfo(return_T)) {
            .int => |info| {
                if (info.signedness != .unsigned or info.bits < 8) {
                    @compileError("cstring_to_int() can only return unsigned integer types (at least u8), found" ++ @tagName(@typeInfo(return_T).int.signedness));
                }
            },
            else => @compileError("cstring_to_int() can only return unsigned integer types (at least u8), found" ++ @tagName(@typeInfo(return_T).int.signedness)),
        }
    }

    // Note(vasilis) these are comptime
    const max_by_10: return_T = std.math.maxInt(return_T) / 10;
    const max_mod_10: return_T = std.math.maxInt(return_T) % 10;

    var result: return_T = 0;
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
