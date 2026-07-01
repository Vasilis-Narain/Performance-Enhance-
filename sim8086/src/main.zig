const std = @import("std");
const Io = std.Io;

const sim8086 = @import("sim8086");
var simRegisters: sim8086.SimulatorRegisters = .{};

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
    var execute = false;
    var dump = false;
    if (args.len == 3) {
        if (std.mem.eql(u8, args[1], "-exec")) {
            filepath = args[2];
            execute = true;
        } else {
            std.debug.print("!{s} argument not recognized!\n", .{args[1]});
            return error.InvalidCall;
        }
    } else if (args.len == 4) {
        if (std.mem.eql(u8, args[2], "-exec") and std.mem.eql(u8, args[1], "-dump")) {
            filepath = args[3];
            execute = true;
            dump = true;
        } else {
            std.debug.print("!arguments not recognized!\n", .{});
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
        const ip_reg: sim8086.SimulatorRegisters.Registers = .ip;
        const bytes_read: u16 = blk: {
            const size = (try file.stat(io)).size;
            var reader = file.reader(io, &.{});
            try reader.interface.readSliceAll(simRegisters.memory[0..@intCast(size)]);
            break :blk @intCast(size);
        };

        if (execute) {
            try stdout_writer.print("\n--- {s} execution ---\n", .{filepath});
        } else {
            try stdout_writer.print("\n; {s} disassembly:\n", .{filepath});
            try stdout_writer.print("bits 16\n\n", .{});
        }

        var instructions_executed: u64 = 0;
        simRegisters.registers[@intFromEnum(ip_reg)] = 0;

        while (simRegisters.registers[@intFromEnum(ip_reg)] < bytes_read) : (instructions_executed += 1) {
            const ip = simRegisters.registers[@intFromEnum(ip_reg)];

            // This is for edge case where peek return shorter array
            var bytes_to_check = [_]u8{0} ** 6;
            const end = @min(ip + 6, bytes_read);
            @memcpy(bytes_to_check[0 .. end - ip], simRegisters.memory[ip..end]);

            var bytes_consumed: u8 = 0;
            var command: sim8086.Command = .{};
            const valid = try sim8086.disassemble(bytes_to_check, &bytes_consumed, &command);
            if (!valid) break;

            // Advance IP before execution
            simRegisters.registers[@intFromEnum(ip_reg)] += bytes_consumed;

            if (execute) {
                try simRegisters.execute(&command);
                try stdout_writer.print("{s} {s}\n", .{ command.command, simRegisters.printString });
                simRegisters.resetBuffers();
            } else {
                try stdout_writer.print("{s}\n", .{command.command});
            }
        }
        if (execute) try stdout_writer.print("\n; Instructions executed: {d}\n", .{instructions_executed});
        if (execute) try simRegisters.printRegisters(stdout_writer);
        try stdout_writer.print("\n", .{});
    } else |err| {
        return err;
    }
    if (dump) {
        var outFile = try Io.Dir.cwd().createFile(io, "output.data", .{});
        defer outFile.close(io);
        var fileout_buffer: [1024]u8 = undefined;
        var file_writer = outFile.writer(io, &fileout_buffer);
        const fileout_writer = &file_writer.interface;
        try fileout_writer.writeAll(&simRegisters.memory);
        try file_writer.flush();
    }
    try stdout_writer.flush();
}
