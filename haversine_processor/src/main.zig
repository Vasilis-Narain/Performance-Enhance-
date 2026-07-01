const std = @import("std");
const Io = std.Io;

const haversine_processor = @import("haversine_processor");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    // TODO: args we'll need:
    //  some way to gen json input (hw 1)
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // This is how you print Hello World kids
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    try stdout_writer.print("Hello World\n", .{});

    // TODO: do the thing
    try haversine_processor.doThing(stdout_writer);

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
