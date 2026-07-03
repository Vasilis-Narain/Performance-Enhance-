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
    var uniform: bool = undefined;
    var call_type: CallType = undefined;
    var seed: u32 = undefined;
    var n: u32 = undefined;

    if (args.len < 2) {
        std.debug.print(
            \\Usage:
            \\  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]" 
            \\  -process [path to json] [path to .f64]
            \\ 
        ,
            .{},
        );
        return;
    }

    if (std.mem.eql(u8, args[1], "-generate")) {
        if (args.len != 5) {
            std.debug.print("Usage:\n  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
            return;
        } else {
            call_type = .generate;
            uniform = blk: {
                if (std.mem.eql(u8, args[2], "uniform")) {
                    break :blk true;
                } else if (std.mem.eql(u8, args[2], "cluster")) {
                    break :blk false;
                } else {
                    std.debug.print("Usage:\n  -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
                    return;
                }
            };
            seed = cstring_to_int(args[3]);
            n = cstring_to_int(args[4]);
        }
    } else if (std.mem.eql(u8, args[1], "-process")) {
        if (args.len < 3) {
            std.debug.print("Usage:\n  -process [path to json] [path to .f64]\n", .{});
            return;
        } else {
            call_type = .process;
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
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // This is how you print Hello World kids
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    switch (call_type) {
        .generate => {
            const method: GenMethod = if (uniform) .uniform else .cluster;
            try stdout_writer.print(
                \\Method: {s}
                \\seed: {d}
                \\n: {d}
                \\
            , .{ @tagName(method), seed, n });

            // Init json output
            var fileNameBuf: [256]u8 = undefined;
            const outFileName = try buildOutFileName(&fileNameBuf, method, .json, n);
            var outFile = try Io.Dir.cwd().createFile(io, outFileName, .{});
            defer outFile.close(io);
            var fileout_buffer: [1024]u8 = undefined;
            var fileout_writer = outFile.writer(io, &fileout_buffer);
            const file_writer = &fileout_writer.interface;

            // Init byte output
            const byteFileName = try buildOutFileName(&fileNameBuf, method, .f64, n);
            var byteFile = try Io.Dir.cwd().createFile(io, byteFileName, .{});
            defer byteFile.close(io);
            var byteout_buffer: [1024]u8 = undefined;
            var byteout_writer = byteFile.writer(io, &byteout_buffer);
            const byte_writer = &byteout_writer.interface;

            var average: f64 = 0;
            try Haversine.generateInput(byte_writer, file_writer, uniform, seed, n, &average);
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

/// Builds Output file name depending on options
fn buildOutFileName(buf: []u8, method: GenMethod, fileType: OutType, n: u32) ![]const u8 {
    return try std.fmt.bufPrint(
        buf,
        "input/{s}_{d}.{s}",
        .{ @tagName(method), n, @tagName(fileType) },
    );
}

/// [NOTE(vasilis)]: this is not safe. It assumes you pass in a string that is a valid number.
/// Why? All my homies hate strings that's why.
fn cstring_to_int(str: [:0]const u8) u32 {
    var result: u32 = 0;
    var len: u8 = 0; // 255 digits are enough to encode a u32...
    while (str[len] != 0) : (len += 1) {}
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        const current = str[i] - 48;
        result += @intCast(current * std.math.pow(u32, 10, @intCast(len - (i + 1))));
    }
    return result;
}
