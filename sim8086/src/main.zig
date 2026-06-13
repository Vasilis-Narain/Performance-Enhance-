const std = @import("std");
const Io = std.Io;

const sim8086 = @import("sim8086");

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("must pass a file/path as argument!\n", .{});
        return error.InvalidCall;
    }
    const filepath = args[1];

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface; // Always remember `&`.

    // Opening file
    if (Io.Dir.cwd().openFile(io, filepath, .{
        .mode = .read_only,
        .lock = .exclusive,
    })) |file| {
        const buf = try arena.alloc(u8, try file.length(io));
        var reader = file.reader(io, buf);
        reader.interface.readSliceAll(buf) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        file.close(io);
        try stdout_writer.print("; {s} disassembly:\n", .{filepath});
        try stdout_writer.print("bits 16\n", .{});
        try sim8086.disassemble(stdout_writer, buf[0..]);
    } else |err| {
        return err;
    }
    try stdout_writer.flush();
}
