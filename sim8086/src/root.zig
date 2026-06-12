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

const Op = enum(u8) {
    mov_rtr = 0b00100010,
    add_rtr = 0b00000000,
    sub_rtr = 0b00001010,
    cmp_rtr = 0b00001110,

    mov_itm = 0b00110001,
    add_sub_cmp_itm = 0b00100000,

    add_ita = 0b00000001,
    sub_ita = 0b00001011,
    cmp_ita = 0b00001111,

    pub fn getOpString(self: @This()) []const u8 {
        return switch (self) {
            .mov_rtr, .mov_itm => "mov",
            .add_rtr, .add_ita => "add",
            .sub_rtr, .sub_ita => "sub",
            .cmp_rtr, .cmp_ita => "cmp",
            else => unreachable,
        };
    }
};

const ItmOp = enum(u8) {
    add = 0b00000000,
    sub = 0b00000101,
    cmp = 0b00000111,
};

/// Disassemble 8086 machine code. All `movs` considered (well not quite, but almost).
/// Should handle all edge cases atm (listing_0040_challenge_movs.asm updated to reflect them)
///
/// See `main.zig` for file load and various initializations.
/// Input:
///     writer: *Io.Writer -> zig way to print to stdout
///     buf: []u8 -> byte buffer
///
/// Sample bit instruction:
///
///     ;Register-to-register:
///     10001001 11011001 -> mov cx, bx
///
pub fn disassemble(writer: *Io.Writer, buf: []u8) Io.Writer.Error!void {
    try writer.print("bits 16\n", .{});
    var i: usize = 0;
    while (i + 1 < buf.len) {
        const buf_i = buf[i];
        const partial_opcode = if (buf_i >> 5 == 0b00000101) buf_i >> 5 else buf_i >> 2;
        // for immediate to register operations, as they'd have same
        // partial op as Register-to-register mov
        if (partial_opcode != 0b00000101) {
            const op: Op = @enumFromInt(partial_opcode);
            switch (op) {

                // Register/memory-to/from-register
                // mov, sub/cmp, add
                .mov_rtr, .cmp_rtr, .sub_rtr, .add_rtr => {
                    const op_str = op.getOpString();

                    try writer.print("{s} ", .{op_str});
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
                // mov, add/sub/cmp
                .mov_itm, .add_sub_cmp_itm => {
                    const op_str = if (op == .mov_itm) "mov" else @tagName(@as(ItmOp, @enumFromInt((buf[i + 1] >> 3) & 0b00000111)));
                    try writer.print("{s} ", .{op_str});
                    const w = buf_i & 0b00000001;
                    const s = (buf_i & 0b00000010) >> 1;

                    const mod = buf[i + 1] >> 6;
                    const rm = buf[i + 1] & 0b00000111;
                    switch (mod) {

                        // Memory Mode 00 no disp except R/M = 110
                        0b00000000 => {
                            const eff_addr = addresses[rm];
                            if (rm != 0b00000110) {
                                var data: u16 = @intCast(buf[i + 2]);
                                if (s == 0 and w == 1) {
                                    const data_hi: u16 = @intCast(buf[i + 3]);
                                    data = (data_hi << 8) | data;
                                    try writer.print("word ", .{});
                                    i += 4;
                                } else {
                                    try writer.print("byte ", .{});
                                    i += 3;
                                }
                                try writer.print("[{s}], {d}\n", .{ eff_addr, data });
                            } else {
                                const addr_lo: u16 = @intCast(buf[i + 2]);
                                const addr_hi: u16 = @intCast(buf[i + 3]);
                                const addr: u16 = (addr_hi << 8) | addr_lo;
                                var data: u16 = @intCast(buf[i + 4]);
                                if (s == 0 and w == 1) {
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
                            if (s == 0 and w == 1) {
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

                            var data: u16 = @intCast(buf[i + 3]);
                            if (s == 0 and w == 1) {
                                try writer.print("word ", .{});
                                const data_hi: u16 = @intCast(buf[i + 4]);
                                data = (data_hi << 8) | data;
                                i += 5;
                            } else {
                                try writer.print("byte ", .{});
                                i += 4;
                            }

                            if (disp == 0) {
                                try writer.print("[{s}], ", .{eff_addr});
                            } else {
                                try writer.print("[{s} {s} {d}], ", .{ eff_addr, sign, disp });
                            }
                            try writer.print("{d}\n", .{data});
                        },
                        else => unreachable,
                    }
                },
                // Immediate to accumulator
                .add_ita, .cmp_ita, .sub_ita => {
                    const op_str = op.getOpString();
                    try writer.print("{s} ", .{op_str});
                    const w = buf_i & 0b00000001;
                    const reg = registers[w * 8];
                    var data: u16 = @intCast(buf[i + 1]);
                    if (w == 1) { //
                        const data_hi: u16 = @intCast(buf[i + 2]);
                        data |= data_hi << 8;
                        i += 1;
                    }
                    try writer.print("{s}, {d}\n", .{ reg, data });
                    i += 2;
                },
            }
        } else {
            // Immediate-to-register OR Memory to accumulator OR Accumulator to memory
            // mov, sub/cmp, add
            // Immediate-to-register
            try writer.print("mov ", .{});
            if (buf_i & 0b00010000 == 0b00010000) {
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
            } else {
                const w = buf_i & 0b00000001;
                var addr: u16 = @intCast(buf[i + 1]);
                const reg = registers[w * 8];
                const addr_hi: u16 = @intCast(buf[i + 2]);
                addr = (addr_hi << 8) | addr;
                if (buf_i & 0b00000010 == 0b00000010) { // Accumulator-to-memory
                    try writer.print("[{d}], {s}\n", .{ addr, reg });
                } else { //Memory-to-accumulator
                    try writer.print("{s}, [{d}]\n", .{ reg, addr });
                }
                i += 3;
            }
        }
    }
    try writer.print("\n", .{});
}
