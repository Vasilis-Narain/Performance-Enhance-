const assert = @import("std").debug.assert;
const Io = @import("std").Io;

// Flat array to index registers via w * 8 + reg (or r/m)
const registers: [16][]const u8 = [_][]const u8{ "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh", "ax", "cx", "dx", "bx", "sp", "bp", "si", "di" };

/// Disassemble 8086 machine code. Only no memory mov considered
///
/// Sample bit instruction:
///     10001001 11011001 -> mov cx, bx
///
pub fn disassemble(writer: *Io.Writer, buf: []u8) Io.Writer.Error!void {
    try writer.print("bits 16\n", .{});
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        const opcode = buf[i] >> 2;
        assert(opcode == 0b00100010); // homework constraints/assists
        try writer.print("mov ", .{});
        const d = (buf[i] & 0b00000011) >> 1;
        const w = (buf[i] & 0b00000011) & 0b00000001;

        const mod = buf[i + 1] >> 6;
        assert(mod == 0b00000011); // homework constraints/assists
        const reg = (buf[i + 1] >> 3) & 0b00000111;
        const rm = buf[i + 1] & 0b00000111;

        const reg_s = registers[w * 8 + reg];
        const rm_s = registers[w * 8 + rm];

        if (d == 1) {
            try writer.print("{s}, {s}\n", .{ reg_s, rm_s });
        } else {
            try writer.print("{s}, {s}\n", .{ rm_s, reg_s });
        }
    }
    try writer.print("\n", .{});
}
