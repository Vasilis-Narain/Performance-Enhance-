const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

// Flat array to index registers via w * 8 + reg (or r/m)
const registers: [16][]const u8 = [_][]const u8{ "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh", "ax", "cx", "dx", "bx", "sp", "bp", "si", "di" };

// Flat array to index address calculations
const addresses: [8][]const u8 = [_][]const u8{
    "bx + si",
    "bx + di",
    "bp + si",
    "bp + di",
    "si",
    "di",
    "bp",
    "bx",
};

/// Disassemble 8086 machine code. All `movs` considered (well not quite, but almost).
///
/// See `main.zig` for file load and various initializations.
/// This function just takes a plain old buffer.
///
/// Sample bit instruction:
///
///     ;Register-to-register:
///     10001001 11011001 -> mov cx, bx
///
///     ; Immediate-to-register:
///     [1011 w reg] [data] [data if w=1]
///     ; 8-bit:
///     [1011 0 001] [12] -> mov cl, 12
///     [1011 0 101] [12] -> mov ch, -12
///     ; 16-bit:
///     [1011 1 reg] [12] [0] -> mov cx, 12
///     [1011 1 reg] [12] [0] -> mov cx, -12
///     [1011 1 reg] [lo] [hi] -> mov dx, 3948
///     [1011 1 reg] [lo] [hi] -> mov dx, -3948
///
pub fn disassemble(writer: *Io.Writer, buf: []u8) Io.Writer.Error!void {
    try writer.print("bits 16\n", .{});
    var i: usize = 0;
    while (i + 1 < buf.len) {
        const buf_i = buf[i];
        const partial_opcode = buf_i >> 5;
        assert(partial_opcode >> 2 == 1);
        switch (partial_opcode) {

            // Register/memory-to/from-register
            0b00000100 => {
                assert(buf_i >> 2 == 0b00100010); // homework constraints/assists
                try writer.print("mov ", .{});
                const d = (buf_i & 0b00000010) >> 1;
                const w = (buf_i & 0b00000001);

                const mod = buf[i + 1] >> 6;
                const reg = (buf[i + 1] >> 3) & 0b00000111;
                const reg_str = registers[w * 8 + reg];
                const rm = buf[i + 1] & 0b00000111;
                switch (mod) {

                    // Register Mode 11
                    0b00000011 => {
                        const rm_str = registers[w * 8 + rm];

                        if (d == 1) {
                            try writer.print("{s}, {s}\n", .{ reg_str, rm_str });
                        } else {
                            try writer.print("{s}, {s}\n", .{ rm_str, reg_str });
                        }
                        i += 2;
                    },

                    // Memory Mode 00 no displacement (except for rm 110 dir addr)
                    0b00000000 => {
                        if (rm != 0b00000110) {
                            const eff_addr = addresses[rm];
                            if (d == 1) {
                                try writer.print("{s}, [{s}]\n", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}\n", .{ eff_addr, reg_str });
                            }
                            i += 2;
                        } else {
                            const data_lo: u16 = @intCast(buf[i + 2]);
                            const data_hi: u16 = @intCast(buf[i + 3]);
                            const data: u16 = (data_hi << 8) | data_lo;
                            try writer.print("{s}, [{d}]\n", .{ reg_str, data });
                            i += 4;
                        }
                    },

                    // Memory Mode 01, 8-bit displacement follows
                    0b00000001 => {
                        const eff_addr = addresses[rm];
                        var data: i8 = @bitCast(buf[i + 2]);
                        const sign = if (data > 0) "+" else "-";
                        if (data < 0) data *= -1;

                        if (data == 0) {
                            if (d == 1) {
                                try writer.print("{s}, [{s}]\n", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}\n", .{ eff_addr, reg_str });
                            }
                        } else {
                            if (d == 1) {
                                try writer.print("{s}, [{s} {s} {d}]\n", .{ reg_str, eff_addr, sign, data });
                            } else {
                                try writer.print("[{s} {s} {d}], {s}\n", .{ eff_addr, sign, data, reg_str });
                            }
                        }
                        i += 3;
                    },

                    // Memory Mode 10, 16-bit displacement follows
                    0b00000010 => {
                        const eff_addr = addresses[rm];
                        const data_lo: u16 = @intCast(buf[i + 2]);
                        const data_hi: u16 = @intCast(buf[i + 3]);
                        var data: i16 = @bitCast((data_hi << 8) | data_lo);
                        const sign = if (data > 0) "+" else "-";
                        if (data < 0) data *= -1;
                        if (data == 0) {
                            if (d == 1) {
                                try writer.print("{s}, [{s}]\n", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}\n", .{ eff_addr, reg_str });
                            }
                        } else {
                            if (d == 1) {
                                try writer.print("{s}, [{s} {s} {d}]\n", .{ reg_str, eff_addr, sign, data });
                            } else {
                                try writer.print("[{s} {s} {d}], {s}\n", .{ eff_addr, sign, data, reg_str });
                            }
                        }
                        i += 4;
                    },

                    else => {
                        std.debug.print("mod: {b}\n", .{mod});
                        break;
                    },
                }
            },
            // Immediate-to-register/memory
            0b00000110 => {
                assert(buf_i >> 1 == 0b01100011);
                try writer.print("mov ", .{});
                const w = buf_i & 0b00000001;

                const mod = buf[i + 1] >> 6;
                const rm = buf[i + 1] & 0b00000111;
                switch (mod) {

                    // Memory Mode 00 no disp except R/M = 110
                    0b00000000 => {
                        const eff_addr = addresses[rm];
                        if (rm != 0b00000110) {
                            try writer.print("[{s}], ", .{eff_addr});
                            var data: u16 = @intCast(buf[i + 2]);
                            if (w == 1) {
                                const data_hi: u16 = @intCast(buf[i + 3]);
                                data = (data_hi << 8) | data;
                                try writer.print("word {d}\n", .{data});
                                i += 4;
                            } else {
                                try writer.print("byte {d}\n", .{data});
                                i += 3;
                            }
                        } else {
                            const addr_lo: u16 = @intCast(buf[i + 2]);
                            const addr_hi: u16 = @intCast(buf[i + 3]);
                            const addr: u16 = (addr_hi << 8) | addr_lo;
                            var data: u16 = @intCast(buf[i + 4]);
                            if (w == 1) {
                                const data_hi: u16 = @intCast(buf[i + 5]);
                                data = (data_hi << 8) | data;
                                try writer.print("word [{d}], {d}\n", .{ addr, data });
                                i += 6;
                            } else {
                                try writer.print("byte [{d}], {d}\n", .{ addr, data });
                                i += 5;
                            }
                        }
                    },

                    // Register Mode 11 no displacement
                    0b00000011 => {
                        const rm_str = registers[w * 8 + rm];
                        var data: u16 = @intCast(buf[i + 2]);
                        if (w == 1) {
                            const data_hi: u16 = @intCast(buf[i + 3]);
                            data = (data_hi << 8) | data;
                            i += 4;
                        } else {
                            i += 3;
                        }
                        try writer.print("{s}, {d}\n", .{ rm_str, data });
                    },

                    // Memory Mode 01, 8-bit displacement follows
                    //  also Memory Mode 10, 16-bit displacement follows
                    0b00000001, 0b00000010 => {
                        const eff_addr = addresses[rm];
                        var disp: i16 = undefined;
                        const disp_lo: u16 = @intCast(buf[i + 2]);

                        if (mod == 0b00000010) {
                            const disp_hi: u16 = @intCast(buf[i + 3]);
                            disp = @bitCast((disp_hi << 8) | disp_lo);
                            i += 1;
                        } else disp = @bitCast(disp_lo);

                        const sign = if (disp > 0) "+" else "-";
                        if (disp < 0) disp *= -1;

                        if (disp == 0) {
                            try writer.print("[{s}], ", .{eff_addr});
                        } else {
                            try writer.print("[{s} {s} {d}], ", .{ eff_addr, sign, disp });
                        }

                        var data: u16 = @intCast(buf[i + 3]);
                        if (w == 0) {
                            try writer.print("byte ", .{});
                            i += 4;
                        } else {
                            try writer.print("word ", .{});
                            const data_hi: u16 = @intCast(buf[i + 4]);
                            data = (data_hi << 8) | data;
                            i += 5;
                        }
                        try writer.print("{d}\n", .{data});
                    },

                    else => {
                        std.debug.print("mod: {b}\n", .{mod});
                        break;
                    },
                }
            },
            // Immediate-to-register OR Memory to accumulator OR Accumulator to memory
            0b00000101 => {
                // Immediate-to-register
                if (buf_i & 0b00010000 == 0b00010000) {
                    try writer.print("mov ", .{});
                    const w = (buf_i >> 3) & 1;
                    const reg = registers[w * 8 + (buf_i & 0b00000111)];
                    try writer.print("{s}, ", .{reg});
                    if (w == 0) {
                        const data: i8 = @bitCast(buf[i + 1]);
                        try writer.print("{d}\n", .{data});
                        i += 2;
                    } else {
                        const data_lo: u16 = @intCast(buf[i + 1]);
                        const data_hi: u16 = @intCast(buf[i + 2]);
                        const data: i16 = @bitCast((data_hi << 8) | data_lo);
                        try writer.print("{d}\n", .{data});
                        i += 3;
                    }
                }
            },
            else => unreachable,
        }
    }
    try writer.print("\n", .{});
}
