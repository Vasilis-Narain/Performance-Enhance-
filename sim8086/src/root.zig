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

const SimulatorRegisters = struct {
    registers: [8]u8 = .{0} ** 8,
    const Registers = enum(u8) {
        ax,
        bx,
        cs,
        dx,
        sp,
        bp,
        si,
        di,
    };
    pub fn getRegisterVal(self: @This(), register: Registers) void {
        return self.registers[@intFromEnum(register)];
    }
    pub fn updateRegister(self: *@This(), register: Registers, new_val: u8) void {
        self.registers[@intFromEnum(register)] = new_val;
    }
};

const Command = struct {
    partial_opcode: ?Op = null,
    itm_op: ?ItmOp = null,
    jump_op: ?JumpOp = null,
    addr: ?[]const u8 = null,
    expl_addr: ?u16 = null,
    reg: ?u8 = null,
    rm: ?u8 = null,
    data: ?u16 = null,
    mod: ?u8 = null,
    displacement: ?u16 = null,
    neg_displ: ?bool = null,
    d: ?u8 = null,
    w: ?u8 = null,
    s: ?u8 = null,
    negative: ?bool = null,
};

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
pub fn disassemble(buf: [6]u8, buf_pos: *u8) Io.Writer.Error!?Command {
    assert(buf_pos.* == 0);
    while (buf_pos.* + 1 < buf.len) {
        const buf_i = buf[buf_pos.*];
        // Check for jumps
        const jump: JumpOp = @enumFromInt(buf_i);
        var command: Command = .{}; // return value
        switch (jump) {
            _ => {},
            else => {
                //const jump_str = @tagName(jump);
                const data: i8 = @bitCast(buf[buf_pos.* + 1]);
                if (data < 0) command.negative = true;
                command.data = buf[buf_pos.* + 1];
                command.jump_op = jump;
                buf_pos.* += 2;
                return command;
                //try writer.print("{s} ($+2)+{d}\n", .{ jump_str, data });
            },
        }
        const partial_opcode = if (buf_i >> 5 == 0b00000101) (buf_i >> 5) | 0b10000000 else buf_i >> 2;
        // for immediate to register operations, as they'd have same
        // partial op as Register-to-register mov
        const op: Op = @enumFromInt(partial_opcode);
        command.partial_opcode = op;
        switch (op) {

            // Register/memory-to/from-register
            // mov, sub/cmp, add
            .mov_rtr, .cmp_rtr, .sub_rtr, .add_rtr, .adc_rtr => {
                //const op_str = op.getOpString();

                //try writer.print("{s} ", .{op_str});
                const d = (buf_i & 0b00000010) >> 1;
                const w = (buf_i & 0b00000001);
                command.d = d;
                command.w = w;

                const mod = buf[buf_pos.* + 1] >> 6;
                command.mod = mod;
                const reg = (buf[buf_pos.* + 1] >> 3) & 0b00000111;
                //const reg_str = registers[w * 8 + reg];
                const rm = buf[buf_pos.* + 1] & 0b00000111;
                switch (mod) {

                    // Register Mode 11
                    0b00000011 => {
                        //const rm_str = registers[w * 8 + rm];

                        if (d == 1) {
                            command.reg = reg;
                            command.rm = rm;
                            //try writer.print("{s}, {s}\n", .{ reg_str, rm_str });
                        } else {
                            command.reg = rm;
                            command.rm = reg;
                            //try writer.print("{s}, {s}\n", .{ rm_str, reg_str });
                        }
                        buf_pos.* += 2;
                        return command;
                    },

                    // Memory Mode 00 no displacement (except for rm 110 dir addr)
                    0b00000000 => {
                        if (rm != 0b00000110) {
                            const eff_addr = addresses[rm];
                            //TODO:
                            //if (d == 1) {
                            //try writer.print("{s}, [{s}]\n", .{ reg_str, eff_addr });
                            //} else {
                            //try writer.print("[{s}], {s}\n", .{ eff_addr, reg_str });
                            //}
                            command.addr = eff_addr;
                            command.reg = reg;
                            buf_pos.* += 2;
                            return command;
                        } else {
                            const data_lo: u16 = @intCast(buf[buf_pos.* + 2]);
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            const data: u16 = (data_hi << 8) | data_lo;
                            command.expl_addr = data;
                            //try writer.print("{s}, [{d}]\n", .{ reg_str, data });
                            buf_pos.* += 4;
                            return command;
                        }
                    },

                    // Memory Mode 01, 8-bit displacement follows
                    0b00000001 => {
                        const eff_addr = addresses[rm];
                        const data: i8 = @bitCast(buf[buf_pos.* + 2]);
                        //const sign = if (data > 0) "+" else "-";
                        var neg = false;
                        if (data < 0) neg = true;
                        command.reg = reg;
                        command.addr = eff_addr;

                        if (data == 0) {
                            //TODO:
                            //if (d == 1) {
                            //try writer.print("{s}, [{s}]\n", .{ reg_str, eff_addr });
                            //} else {
                            //try writer.print("[{s}], {s}\n", .{ eff_addr, reg_str });
                            //}
                        } else {
                            //TODO:
                            //if (d == 1) {
                            //try writer.print("{s}, [{s} {s} {d}]\n", .{ reg_str, eff_addr, sign, data });
                            //} else {
                            //try writer.print("[{s} {s} {d}], {s}\n", .{ eff_addr, sign, data, reg_str });
                            //}
                            command.neg_displ = neg;
                            command.displacement = @intCast(buf[buf_pos.* + 2]);
                        }
                        buf_pos.* += 3;
                        return command;
                    },

                    // Memory Mode 10, 16-bit displacement follows
                    0b00000010 => {
                        const eff_addr = addresses[rm];
                        const data_lo: u16 = @intCast(buf[buf_pos.* + 2]);
                        const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                        var data: i16 = @bitCast((data_hi << 8) | data_lo);
                        const neg = if (data >= 0) false else true;
                        if (data < 0) data *= -1;
                        if (data == 0) {
                            //TODO:
                            //if (d == 1) {
                            //try writer.print("{s}, [{s}]\n", .{ reg_str, eff_addr });
                            //} else {
                            //try writer.print("[{s}], {s}\n", .{ eff_addr, reg_str });
                            //}
                            command.reg = reg;
                            command.addr = eff_addr;
                        } else {
                            //TODO:
                            //if (d == 1) {
                            //try writer.print("{s}, [{s} {s} {d}]\n", .{ reg_str, eff_addr, sign, data });
                            //} else {
                            //try writer.print("[{s} {s} {d}], {s}\n", .{ eff_addr, sign, data, reg_str });
                            //}
                            command.neg_displ = neg;
                            command.displacement = (data_hi << 8) | data_lo;
                        }
                        buf_pos.* += 4;
                        return command;
                    },

                    else => unreachable,
                }
            },
            // Immediate-to-register/memory
            // mov, add/sub/cmp
            .mov_itm, .arithmetic_itm => {
                //const op_str = if (op == .mov_itm) "mov" else @tagName(@as(ItmOp, @enumFromInt((buf[buf_pos.* + 1] >> 3) & 0b00000111)));
                //try writer.print("{s} ", .{op_str});
                const w = buf_i & 0b00000001;
                //const w_keyword = if (w == 1) "word" else "byte";
                const s = if (op == .mov_itm) 0 else (buf_i & 0b00000010) >> 1;
                command.w = w;
                command.s = s;

                const mod = buf[buf_pos.* + 1] >> 6;
                command.mod = mod;
                const rm = buf[buf_pos.* + 1] & 0b00000111;
                command.rm = rm;
                switch (mod) {

                    // Memory Mode 00 no disp except R/M = 110
                    0b00000000 => {
                        const eff_addr = addresses[rm];
                        if (rm != 0b00000110) {
                            var data: u16 = @intCast(buf[buf_pos.* + 2]);
                            if (s == 0 and w == 1) {
                                const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                                data = (data_hi << 8) | data;
                                buf_pos.* += 4;
                            } else {
                                buf_pos.* += 3;
                            }
                            command.data = data;
                            command.addr = eff_addr;
                            return command;
                            //try writer.print("{s} [{s}], {d}\n", .{ w_keyword, eff_addr, data });
                        } else {
                            const addr_lo: u16 = @intCast(buf[buf_pos.* + 2]);
                            const addr_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            const addr: u16 = (addr_hi << 8) | addr_lo;
                            var data: u16 = @intCast(buf[buf_pos.* + 4]);
                            if (s == 0 and w == 1) {
                                const data_hi: u16 = @intCast(buf[buf_pos.* + 5]);
                                data = (data_hi << 8) | data;
                                buf_pos.* += 6;
                            } else {
                                buf_pos.* += 5;
                            }
                            command.data = data;
                            command.expl_addr = addr;
                            return command;
                            //try writer.print("{s} [{d}], {d}\n", .{ w_keyword, addr, data });
                        }
                    },

                    // Register Mode 11 no displacement
                    0b00000011 => {
                        //const rm_str = registers[w * 8 + rm];
                        var data: u16 = @intCast(buf[buf_pos.* + 2]);
                        if (s == 0 and w == 1) {
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            data = (data_hi << 8) | data;
                            buf_pos.* += 4;
                        } else {
                            buf_pos.* += 3;
                        }
                        command.data = data;
                        return command;
                        //try writer.print("{s}, {d}\n", .{ rm_str, data });
                    },

                    // Memory Mode 01, 8-bit displacement follows
                    //  also Memory Mode 10, 16-bit displacement follows
                    0b00000001, 0b00000010 => {
                        const eff_addr = addresses[rm];
                        var disp: i16 = undefined;
                        var disp_u16: u16 = @intCast(buf[buf_pos.* + 2]);

                        if (mod == 0b00000010) {
                            const disp_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            disp_u16 |= disp_hi << 8;
                            disp = @bitCast((disp_hi << 8) | disp_u16);
                            buf_pos.* += 1;
                        } else disp = @bitCast(disp_u16);

                        const disp_neg = if (disp >= 0) false else true;
                        //if (disp < 0) disp *= -1;

                        var data: u16 = @intCast(buf[buf_pos.* + 3]);
                        if (s == 0 and w == 1) {
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 4]);
                            data = (data_hi << 8) | data;
                            buf_pos.* += 5;
                        } else {
                            buf_pos.* += 4;
                        }
                        //TODO:
                        //try writer.print("{s} ", .{w_keyword});

                        command.addr = eff_addr;
                        command.neg_displ = disp_neg;
                        command.displacement = disp_u16;
                        command.data = data;
                        return command;
                        //TODO:
                        //if (disp == 0) {
                        //try writer.print("[{s}], ", .{eff_addr});
                        //} else {
                        //try writer.print("[{s} {s} {d}], ", .{ eff_addr, sign, disp });
                        //}
                        //try writer.print("{d}\n", .{data});
                    },
                    else => unreachable,
                }
            },
            // Immediate to accumulator
            .add_ita, .adc_ita, .cmp_ita, .sub_ita => {
                //const op_str = op.getOpString();
                //try writer.print("{s} ", .{op_str});
                const w = buf_i & 0b00000001;
                //const reg = registers[w * 8];
                var data: u16 = @intCast(buf[buf_pos.* + 1]);
                if (w == 1) { //
                    const data_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                    data |= data_hi << 8;
                    buf_pos.* += 1;
                }
                buf_pos.* += 2;
                command.w = w;
                command.reg = 0;
                command.data = data;
                return command;
                //try writer.print("{s}, {d}\n", .{ reg, data });
            },
            .mov_xtra => {
                // Immediate-to-register OR Memory to accumulator OR Accumulator to memory
                // mov, sub/cmp, add
                // Immediate-to-register
                //const op_str = op.getOpString();
                //try writer.print("{s} ", .{op_str});
                if (buf_i & 0b00010000 == 0b00010000) {
                    const w = (buf_i >> 3) & 1;
                    //const reg = registers[w * 8 + (buf_i & 0b00000111)];
                    command.reg = buf_i & 0b00000111;
                    var data: u16 = undefined;
                    //try writer.print("{s}, ", .{reg});
                    if (w == 0) {
                        data = @intCast(buf[buf_pos.* + 1]);
                        //try writer.print("{d}\n", .{data});
                        buf_pos.* += 2;
                    } else {
                        data = @intCast(buf[buf_pos.* + 1]);
                        const data_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                        data |= data_hi << 8;
                        //try writer.print("{d}\n", .{data});
                        buf_pos.* += 3;
                    }
                    command.data = data;
                    return command;
                } else { //Accumulator-to-memory or Memory-to-accumulator
                    const w = buf_i & 0b00000001;
                    var addr: u16 = @intCast(buf[buf_pos.* + 1]);
                    //const reg = registers[w * 8];
                    command.reg = w * 8;
                    const addr_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                    addr = (addr_hi << 8) | addr;
                    command.expl_addr = addr;
                    if (buf_i & 0b00000010 == 0b00000010) { // Accumulator-to-memory
                        command.d = 1;
                        //try writer.print("[{d}], {s}\n", .{ addr, reg });
                    } else { //Memory-to-accumulator
                        command.d = 0;
                        //try writer.print("{s}, [{d}]\n", .{ reg, addr });
                    }
                    buf_pos.* += 3;
                    return command;
                }
            },
        }
    }
    return null;
    //try writer.print("\n", .{});
}
