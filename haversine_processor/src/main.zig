const std = @import("std");
const Io = std.Io;

const haversine_processor = @import("haversine_processor");

/// CLI level API:
///     `-generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]`
pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var uniform: bool = undefined;
    var seed: u32 = undefined;
    var n: u32 = undefined;

    if (args.len != 5 or !std.mem.eql(u8, args[1], "-generate")) {
        std.debug.print("Usage: -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
        return;
    } else {
        uniform = blk: {
            if (std.mem.eql(u8, args[2], "uniform")) {
                break :blk true;
            } else if (std.mem.eql(u8, args[2], "cluster")) {
                break :blk false;
            } else {
                std.debug.print("Usage: -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
                return;
            }
        };
        seed = cstring_to_int(args[3]);
        n = cstring_to_int(args[4]);
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // This is how you print Hello World kids
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // TODO(vasilis): do the thing
    try haversine_processor.generateInput(stdout_writer, uniform, seed, n);

    if (false) {
        // TODO: output the thing
        var outFile = try Io.Dir.cwd().createFile(io, "input/haversine_input.json", .{});
        defer outFile.close(io);
        var fileout_buffer: [1024]u8 = undefined;
        var fileout_writer = outFile.writer(io, &fileout_buffer);
        const file_writer = &fileout_writer.interface;
        try file_writer.writeAll(); // TODO: might be wise to pass what we're writing as an argument :D
        try file_writer.flush();
    }

    // FLUSHING!
    try stdout_writer.flush(); // Don't forget to flush!
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
