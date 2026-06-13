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
    mov_xtra = 0b10000101, // sentinel for special cases

    mov_rtr = 0b00100010,
    add_rtr = 0b00000000,
    adc_rtr = 0b00000100,
    sub_rtr = 0b00001010,
    cmp_rtr = 0b00001110,

    mov_itm = 0b00110001,
    arithmetic_itm = 0b00100000,

    add_ita = 0b00000001,
    adc_ita = 0b00000101,
    sub_ita = 0b00001011,
    cmp_ita = 0b00001111,

    pub fn getOpString(self: @This()) []const u8 {
        return switch (self) {
            .mov_rtr, .mov_itm, .mov_xtra => "mov",
            .add_rtr, .add_ita => "add",
            .adc_rtr, .adc_ita => "adc",
            .sub_rtr, .sub_ita => "sub",
            .cmp_rtr, .cmp_ita => "cmp",
            else => unreachable,
        };
    }
};

const ItmOp = enum(u8) {
    add = 0b00000000,
    adc = 0b00000010,
    sub = 0b00000101,
    cmp = 0b00000111,
};

const JumpOp = enum(u8) {
    je = 0b01110100,
    jl = 0b01111100,
    jle = 0b01111110,
    jb = 0b01110010,
    jbe = 0b01110110,
    jp = 0b01111010,
    jo = 0b01110000,
    js = 0b01111000,
    jnz = 0b01110101,
    jnl = 0b01111101,
    jg = 0b01111111,
    jnb = 0b01110011,
    ja = 0b01110111,
    jnp = 0b01111011,
    jno = 0b01110001,
    jns = 0b01111001,
    loop = 0b11100010,
    loopz = 0b11100001,
    loopnz = 0b11100000,
    jcxz = 0b11100011,
    _,
};

const Command = struct {};

/// Disassemble 8086 machine code. All `movs` considered (well not quite, but almost).
/// Should handle all edge cases atm (listing_0040_challenge_movs.asm updated to reflect them)
/// And also add sub cmp and jumps
///
/// Is it pretty? No. Is it extendable? Probably not. Does it work? Well, it passes the test.
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
    var i: usize = 0;
    while (i + 1 < buf.len) {
        const buf_i = buf[i];
        // Check for jumps
        const jump: JumpOp = @enumFromInt(buf_i);
        switch (jump) {
            _ => {},
            else => {
                const jump_str = @tagName(jump);
                const data: i8 = @bitCast(buf[i + 1]);
                try writer.print("{s} ($+2)+{d}\n", .{ jump_str, data });
                i += 2;
                continue;
            },
        }
        const partial_opcode = if (buf_i >> 5 == 0b00000101) (buf_i >> 5) | 0b10000000 else buf_i >> 2;
        // for immediate to register operations, as they'd have same
        // partial op as Register-to-register mov
        const op: Op = @enumFromInt(partial_opcode);
        switch (op) {

            // Register/memory-to/from-register
            // mov, sub/cmp, add
            .mov_rtr, .cmp_rtr, .sub_rtr, .add_rtr, .adc_rtr => {
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
                        break;
                    },
                }
            },
            // Immediate-to-register/memory
            // mov, add/sub/cmp
            .mov_itm, .arithmetic_itm => {
                const op_str = if (op == .mov_itm) "mov" else @tagName(@as(ItmOp, @enumFromInt((buf[i + 1] >> 3) & 0b00000111)));
                try writer.print("{s} ", .{op_str});
                const w = buf_i & 0b00000001;
                const w_keyword = if (w == 1) "word" else "byte";
                const s = if (op == .mov_itm) 0 else (buf_i & 0b00000010) >> 1;

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
                                i += 4;
                            } else {
                                i += 3;
                            }
                            try writer.print("{s} [{s}], {d}\n", .{ w_keyword, eff_addr, data });
                        } else {
                            const addr_lo: u16 = @intCast(buf[i + 2]);
                            const addr_hi: u16 = @intCast(buf[i + 3]);
                            const addr: u16 = (addr_hi << 8) | addr_lo;
                            var data: u16 = @intCast(buf[i + 4]);
                            if (s == 0 and w == 1) {
                                const data_hi: u16 = @intCast(buf[i + 5]);
                                data = (data_hi << 8) | data;
                                i += 6;
                            } else {
                                i += 5;
                            }
                            try writer.print("{s} [{d}], {d}\n", .{ w_keyword, addr, data });
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
                            const data_hi: u16 = @intCast(buf[i + 4]);
                            data = (data_hi << 8) | data;
                            i += 5;
                        } else {
                            i += 4;
                        }
                        try writer.print("{s} ", .{w_keyword});

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
            .add_ita, .adc_ita, .cmp_ita, .sub_ita => {
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
            .mov_xtra => {
                // Immediate-to-register OR Memory to accumulator OR Accumulator to memory
                // mov, sub/cmp, add
                // Immediate-to-register
                const op_str = op.getOpString();
                try writer.print("{s} ", .{op_str});
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
            },
        }
    }
    try writer.print("\n", .{});
}
