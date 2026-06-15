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

    //pub fn disassemble(buf: [6]u8, buf_pos: *u8) Io.Writer.Error!?Command {
    //
    // Opening file
    if (Io.Dir.cwd().openFile(io, filepath, .{
        .mode = .read_only,
        .lock = .exclusive,
    })) |file| {
        defer file.close(io);
        var buf: [4096]u8 = undefined; // Grab a decent sized 'page' to reduce IO calls
        // but also being able to handle _large_ files in stack by not loading entire file to
        // buffer.
        var reader = file.reader(io, &buf);
        var instructions_read: u16 = 0;
        try stdout_writer.print("; {s} disassembly:\n", .{filepath});
        try stdout_writer.print("bits 16\n", .{});
        while (true) : (instructions_read += 1) {
            reader.interface.fill(6) catch |err| switch (err) {
                error.EndOfStream => {},
                error.ReadFailed => return reader.err.?,
            };

            const bytes = reader.interface.buffered();
            if (bytes.len == 0) break;

            const window = bytes[0..@min(6, bytes.len)];
            var bytes_to_check = [_]u8{0} ** 6; // zero-initialise array we're checking
            @memcpy(bytes_to_check[0..window.len], window); // This is for edge case where peek return shorter array

            var bytes_consumed: u8 = 0;
            const command = try sim8086.disassemble(bytes_to_check, &bytes_consumed);
            _ = command;
            reader.interface.toss(@min(bytes_consumed, window.len));
        }
        try stdout_writer.print("; Instructions read: {d}\n", .{instructions_read});
    } else |err| {
        return err;
    }
    try stdout_writer.flush();
}
