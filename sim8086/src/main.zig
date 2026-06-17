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
    var filepath: [:0]const u8 = undefined;
    var execute: bool = false;
    if (args.len == 3) {
        if (std.mem.eql(u8, args[1], "-exec")) {
            filepath = args[2];
            execute = true;
        } else {
            std.debug.print("!{s} argument not recognized!\n", .{args[1]});
            return error.InvalidCall;
        }
    } else {
        filepath = args[1];
    }

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
        defer file.close(io);
        var simRegisters: sim8086.SimulatorRegisters = .{};
        var buf: [4096]u8 = undefined; // Grab a decent sized 'page' to reduce IO calls
        var reader = file.reader(io, &buf); //zig magic... this thing has pointers internally to know when to grab a new page: Magic.
        var instructions_read: u16 = 0;
        if (execute) {
            try stdout_writer.print("\n--- {s} execution ---\n", .{filepath});
        } else {
            try stdout_writer.print("\n; {s} disassembly:\n", .{filepath});
            try stdout_writer.print("bits 16\n\n", .{});
        }
        while (true) : (instructions_read += 1) {
            reader.interface.fill(6) catch |err| switch (err) {
                error.EndOfStream => {},
                error.ReadFailed => return reader.err.?,
            };

            const bytes = reader.interface.buffered();
            if (bytes.len == 0) break;

            const window = bytes[0..@min(6, bytes.len)];

            // This is for edge case where peek return shorter array
            var bytes_to_check = [_]u8{0} ** 6;
            @memcpy(bytes_to_check[0..window.len], window);

            var bytes_consumed: u8 = 0;
            const command = try sim8086.disassemble(bytes_to_check, &bytes_consumed);
            if (execute) {
                try simRegisters.execute(&command.?);
                try stdout_writer.print("{s} {s}\n", .{ command.?.command, simRegisters.printString });
                simRegisters.resetBuffers();
            } else {
                try stdout_writer.print("{s}\n", .{command.?.command});
            }
            reader.interface.toss(@min(bytes_consumed, window.len));
        }
        if (!execute) try stdout_writer.print("\n; Instructions read: {d}\n", .{instructions_read});
        if (execute) try simRegisters.printRegisters(stdout_writer);
        try stdout_writer.print("\n", .{});
    } else |err| {
        return err;
    }
    try stdout_writer.flush();
}
