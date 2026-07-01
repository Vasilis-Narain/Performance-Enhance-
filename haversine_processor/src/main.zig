const std = @import("std");
const Io = std.Io;

const haversine_processor = @import("haversine_processor");

// NOTE(vasilis):
//      CLI level API:
//          executable -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]
//
pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var uniform: bool = undefined;
    var seed: u32 = undefined;
    var n: u32 = undefined;

    // TODO(vasilis): silly me forgot that args are strings..
    if (args.len != 5 or !std.mem.eql(u8, args[1], "-generate")) {
        std.debug.print("Usage: -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]\n", .{});
        return;
    } else {
        uniform = args[2];
        seed = args[3];
        n = args[4];
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // This is how you print Hello World kids
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print("Hello World\n", .{});

    try haversine_processor.generateInput(stdout_writer, uniform, seed, n);

    {
        // TODO: output the thing
        var outFile = try Io.Dir.cwd().createFile(io, "input/haversine_input.json", .{});
        defer outFile.close(io);
        var fileout_buffer: [1024]u8 = undefined;
        var fileout_writer = outFile.writer(io, &fileout_buffer);
        const file_writer = &fileout_writer.interface;
        try file_writer.writeAll(); // TODO: put what we're writing :D
        try file_writer.flush();
    }

    // FLUSHING!
    try stdout_writer.flush(); // Don't forget to flush!
}
