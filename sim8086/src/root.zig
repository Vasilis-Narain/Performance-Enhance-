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
//.mov_xtra => {
//// Immediate-to-register OR Memory to accumulator OR Accumulator to memory
//// mov, sub/cmp, add
//// Immediate-to-register
///
//if (buf_i & 0b00010000 == 0b00010000) { immediate to register
//if (buf_i & 0b00000010 == 0b00000010) { // Accumulator-to-memory
//} else { //Memory-to-accumulator
//
const movXtraType = enum(u8) {
    itr, // immediate-to-register
    atm, // accumulator-to-memory
    mta, // memory-to-accumulator
    //
    pub fn init(buf_i: u8) @This() {
        if (buf_i & 0b00010000 == 0b00010000) { //immediate to register
            return .itr;
        }
        if (buf_i & 0b00000010 == 0b00000010) { // Accumulator-to-memory
            return .atm;
        }
        return .mta;
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

pub const SimulatorRegisters = struct {
    printBuf: [64]u8 = undefined,
    printString: []const u8 = &.{},
    registers: [8]u16 = .{0} ** 8,

    pub const Registers = enum(u8) {
        ax,
        bx,
        cx,
        dx,
        sp,
        bp,
        si,
        di,
    };
    pub const Registers_8bit = enum(u8) {
        ah,
        bh,
        ch,
        dh,
        al,
        bl,
        cl,
        dl,

        pub fn getRegister16bit(self: @This()) Registers {
            return switch (self) {
                .ah, .al => .ax,
                .bh, .bl => .bx,
                .ch, .cl => .cx,
                .dh, .dl => .dx,
            };
        }
    };
    pub fn getRegisterVal(self: @This(), register: Registers) u16 {
        return self.registers[@intFromEnum(register)];
    }
    pub fn updateRegister(self: *@This(), register: Registers, new_val: u16, is_lo: bool) void {
        if (is_lo) {
            self.registers[@intFromEnum(register)] = (self.registers[@intFromEnum(register)] & 0xFF00) | new_val;
        } else {
            self.registers[@intFromEnum(register)] = (self.registers[@intFromEnum(register)] & 0x00FF) | (new_val << 8);
        }
    }
    pub fn execute(self: *@This(), command: *const Command) !void {
        var writer = Io.Writer.fixed(&self.printBuf);
        if (command.jump_op) |jmp_op| {
            _ = jmp_op;
            return;
        }
        if (command.partial_opcode) |partial_opcode| {
            switch (partial_opcode) {
                .mov_rtr => {
                    const diff: u8 = if (command.w.? == 1) 0 else 8;
                    var reg_8: Registers_8bit = undefined;
                    var reg: Registers = undefined;
                    const mod = command.mod.?;
                    switch (mod) {
                        0b00000011 => {
                            var reg_lo: bool = true;
                            var rm_lo: bool = true;
                            var rm_8: Registers_8bit = undefined;
                            var rm: Registers = undefined;
                            if (diff > 0) {
                                reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                rm_8 = std.meta.stringToEnum(Registers_8bit, registers[command.rm.?]).?;
                                reg = reg_8.getRegister16bit();
                                rm = rm_8.getRegister16bit();
                                if (@intFromEnum(reg_8) < 4) {
                                    reg_lo = false;
                                }
                                if (@intFromEnum(rm_8) < 4) {
                                    rm_lo = false;
                                }
                            } else {
                                reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                rm = std.meta.stringToEnum(Registers, registers[command.rm.?]).?;
                            }
                            const prev_data = self.getRegisterVal(reg);
                            var data: u16 = self.getRegisterVal(rm);
                            if (!rm_lo) {
                                data >>= 8;
                            }
                            self.updateRegister(reg, data, reg_lo);
                            try writer.print("; {s}:0x{x:0>4}->0x{x:0>4}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                            self.printString = writer.buffered();
                        },
                        else => {},
                    }
                },
                .mov_xtra => {
                    const mov_type = command.mov_xtra_type.?;
                    const diff: u8 = if (command.w.? == 1) 0 else 8;
                    var reg_8: Registers_8bit = undefined;
                    var reg: Registers = undefined;
                    var is_lo: bool = true;
                    if (diff > 0) {
                        reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                        reg = reg_8.getRegister16bit();
                        if (@intFromEnum(reg_8) < 4) {
                            is_lo = false;
                        }
                    } else {
                        reg = std.meta.stringToEnum(Registers, registers[command.reg.? + diff]).?;
                    }

                    switch (mov_type) {
                        .itr => {
                            const prev_data = self.getRegisterVal(reg);
                            self.updateRegister(reg, command.data.?, is_lo);
                            try writer.print("; {s}:0x{x:0>4}->0x{x:0>4}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                            self.printString = writer.buffered();
                        },
                        .atm => {},
                        .mta => {},
                    }
                },
                else => return,
            }
        }
    }
    pub fn resetBuffers(self: *@This()) void {
        self.printBuf = undefined;
        self.printString = &.{};
    }

    pub fn printRegisters(self: @This(), writer: *Io.Writer) !void {
        try writer.print("\nFinal registers:\n", .{});
        var i: u8 = 0;
        while (i < @typeInfo(Registers).@"enum".fields.len) : (i += 1) {
            const reg: Registers = @enumFromInt(i);
            const data: u16 = self.getRegisterVal(reg);
            try writer.print(
                "    {s}: 0x{x:0>4} ({d})\n",
                .{
                    @tagName(reg),
                    data,
                    data,
                },
            );
        }
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
    mov_xtra_type: ?movXtraType = null,
    d: ?u8 = null,
    w: ?u8 = null,
    s: ?u8 = null,
    negative: ?bool = null,
    commandBuf: [64]u8 = undefined,
    command: []const u8 = &.{},
};

/// See `main.zig` for file load and various initializations.
/// Input:
///     buf: []u8 -> byte buffer
///     buf_pos: *u8 -> reference holding how many bytes processed (starts at 0)
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
        var writer: std.Io.Writer = .fixed(&command.commandBuf);
        switch (jump) {
            _ => {},
            else => {
                const jump_str = @tagName(jump);
                const data: i8 = @bitCast(buf[buf_pos.* + 1]);
                if (data < 0) command.negative = true;
                command.data = buf[buf_pos.* + 1];
                command.jump_op = jump;
                buf_pos.* += 2;
                try writer.print("{s} ($+2)+{d}", .{ jump_str, data });
                command.command = writer.buffered();
                return command;
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
                const op_str = op.getOpString();

                try writer.print("{s} ", .{op_str});
                const d = (buf_i & 0b00000010) >> 1;
                const w = (buf_i & 0b00000001);
                command.d = d;
                command.w = w;

                const mod = buf[buf_pos.* + 1] >> 6;
                command.mod = mod;
                const reg = (buf[buf_pos.* + 1] >> 3) & 0b00000111;
                const reg_str = registers[w * 8 + reg];
                const rm = buf[buf_pos.* + 1] & 0b00000111;
                switch (mod) {

                    // Register Mode 11
                    0b00000011 => {
                        const rm_str = registers[w * 8 + rm];

                        if (d == 1) {
                            command.reg = reg + w * 8;
                            command.rm = rm + w * 8;
                            try writer.print("{s}, {s}", .{ reg_str, rm_str });
                        } else {
                            command.reg = rm + w * 8;
                            command.rm = reg + w * 8;
                            try writer.print("{s}, {s}", .{ rm_str, reg_str });
                        }
                        command.command = writer.buffered();
                        buf_pos.* += 2;
                        return command;
                    },

                    // Memory Mode 00 no displacement (except for rm 110 dir addr)
                    0b00000000 => {
                        if (rm != 0b00000110) {
                            const eff_addr = addresses[rm];
                            //TODO:
                            if (d == 1) {
                                try writer.print("{s}, [{s}]", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}", .{ eff_addr, reg_str });
                            }
                            command.addr = eff_addr;
                            command.reg = reg;
                            command.command = writer.buffered();
                            buf_pos.* += 2;
                            return command;
                        } else {
                            const data_lo: u16 = @intCast(buf[buf_pos.* + 2]);
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            const data: u16 = (data_hi << 8) | data_lo;
                            command.expl_addr = data;
                            try writer.print("{s}, [{d}]", .{ reg_str, data });
                            command.command = writer.buffered();
                            buf_pos.* += 4;
                            return command;
                        }
                    },

                    // Memory Mode 01, 8-bit displacement follows
                    0b00000001 => {
                        const eff_addr = addresses[rm];
                        var data: i8 = @bitCast(buf[buf_pos.* + 2]);
                        const sign = if (data > 0) "+" else "-";
                        var neg = false;
                        if (data < 0) {
                            data *= -1;
                            neg = true;
                        }

                        command.reg = reg;
                        command.addr = eff_addr;

                        if (data == 0) {
                            if (d == 1) {
                                try writer.print("{s}, [{s}]", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}", .{ eff_addr, reg_str });
                            }
                        } else {
                            if (d == 1) {
                                try writer.print("{s}, [{s} {s} {d}]", .{ reg_str, eff_addr, sign, data });
                            } else {
                                try writer.print("[{s} {s} {d}], {s}", .{ eff_addr, sign, data, reg_str });
                            }
                            command.neg_displ = neg;
                            command.displacement = @intCast(buf[buf_pos.* + 2]);
                        }
                        command.command = writer.buffered();
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
                        const sign = if (!neg) "+" else "-";
                        if (data < 0) data *= -1;
                        if (data == 0) {
                            if (d == 1) {
                                try writer.print("{s}, [{s}]", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}", .{ eff_addr, reg_str });
                            }
                            command.reg = reg;
                            command.addr = eff_addr;
                        } else {
                            if (d == 1) {
                                try writer.print("{s}, [{s} {s} {d}]", .{ reg_str, eff_addr, sign, data });
                            } else {
                                try writer.print("[{s} {s} {d}], {s}", .{ eff_addr, sign, data, reg_str });
                            }
                            command.neg_displ = neg;
                            command.displacement = (data_hi << 8) | data_lo;
                        }
                        command.command = writer.buffered();
                        buf_pos.* += 4;
                        return command;
                    },

                    else => unreachable,
                }
            },
            // Immediate-to-register/memory
            // mov, add/sub/cmp
            .mov_itm, .arithmetic_itm => {
                const op_str = if (op == .mov_itm) "mov" else @tagName(@as(ItmOp, @enumFromInt((buf[buf_pos.* + 1] >> 3) & 0b00000111)));
                try writer.print("{s} ", .{op_str});
                const w = buf_i & 0b00000001;
                const w_keyword = if (w == 1) "word" else "byte";
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
                            try writer.print("{s} [{s}], {d}", .{ w_keyword, eff_addr, data });
                            command.data = data;
                            command.addr = eff_addr;
                            command.command = writer.buffered();
                            return command;
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
                            try writer.print("{s} [{d}], {d}", .{ w_keyword, addr, data });
                            command.data = data;
                            command.expl_addr = addr;
                            command.command = writer.buffered();
                            return command;
                        }
                    },

                    // Register Mode 11 no displacement
                    0b00000011 => {
                        const rm_str = registers[w * 8 + rm];
                        var data: u16 = @intCast(buf[buf_pos.* + 2]);
                        if (s == 0 and w == 1) {
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            data = (data_hi << 8) | data;
                            buf_pos.* += 4;
                        } else {
                            buf_pos.* += 3;
                        }
                        try writer.print("{s}, {d}", .{ rm_str, data });
                        command.data = data;
                        command.command = writer.buffered();
                        return command;
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
                        const sign = if (!disp_neg) "+" else "-";
                        if (disp < 0) disp *= -1;

                        var data: u16 = @intCast(buf[buf_pos.* + 3]);
                        if (s == 0 and w == 1) {
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 4]);
                            data = (data_hi << 8) | data;
                            buf_pos.* += 5;
                        } else {
                            buf_pos.* += 4;
                        }
                        try writer.print("{s} ", .{w_keyword});
                        if (disp == 0) {
                            try writer.print("[{s}], ", .{eff_addr});
                        } else {
                            try writer.print("[{s} {s} {d}], ", .{ eff_addr, sign, disp });
                        }
                        try writer.print("{d}", .{data});

                        command.addr = eff_addr;
                        command.neg_displ = disp_neg;
                        command.displacement = disp_u16;
                        command.data = data;
                        command.command = writer.buffered();
                        return command;
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
                var data: u16 = @intCast(buf[buf_pos.* + 1]);
                if (w == 1) { //
                    const data_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                    data |= data_hi << 8;
                    buf_pos.* += 1;
                }
                try writer.print("{s}, {d}", .{ reg, data });
                command.w = w;
                command.reg = 0;
                command.data = data;
                command.command = writer.buffered();
                buf_pos.* += 2;
                return command;
            },
            .mov_xtra => {
                // Immediate-to-register OR Memory to accumulator OR Accumulator to memory
                // mov, sub/cmp, add
                // Immediate-to-register
                const op_str = op.getOpString();
                try writer.print("{s} ", .{op_str});
                command.mov_xtra_type = .init(buf_i);
                switch (command.mov_xtra_type.?) {
                    //if (buf_i & 0b00010000 == 0b00010000) {
                    .itr => {
                        const w = (buf_i >> 3) & 1;
                        command.w = w;
                        const reg = registers[w * 8 + (buf_i & 0b00000111)];
                        command.reg = w * 8 + (buf_i & 0b00000111);
                        var data: u16 = undefined;
                        try writer.print("{s}, ", .{reg});
                        if (w == 0) {
                            data = @intCast(buf[buf_pos.* + 1]);
                            try writer.print("{d}", .{data});
                            buf_pos.* += 2;
                        } else {
                            data = @intCast(buf[buf_pos.* + 1]);
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                            data |= data_hi << 8;
                            try writer.print("{d}", .{data});
                            buf_pos.* += 3;
                        }
                        command.data = data;
                        command.command = writer.buffered();
                        return command;
                    }, //else { //Accumulator-to-memory or Memory-to-accumulator

                    .atm => {
                        const w = buf_i & 0b00000001;
                        command.w = w;
                        var addr: u16 = @intCast(buf[buf_pos.* + 1]);
                        const reg = registers[w * 8];
                        command.reg = w * 8;
                        const addr_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                        addr = (addr_hi << 8) | addr;
                        command.expl_addr = addr;
                        //if (buf_i & 0b00000010 == 0b00000010) { // Accumulator-to-memory
                        command.d = 1;
                        try writer.print("[{d}], {s}", .{ addr, reg });
                        command.command = writer.buffered();
                        buf_pos.* += 3;
                        return command;
                    }, //else { //Memory-to-accumulator
                    .mta => {
                        const w = buf_i & 0b00000001;
                        command.w = w;
                        var addr: u16 = @intCast(buf[buf_pos.* + 1]);
                        const reg = registers[w * 8];
                        command.reg = w * 8;
                        const addr_hi: u16 = @intCast(buf[buf_pos.* + 2]);
                        addr = (addr_hi << 8) | addr;
                        command.expl_addr = addr;
                        command.d = 0;
                        try writer.print("{s}, [{d}]", .{ reg, addr });
                        command.command = writer.buffered();
                        buf_pos.* += 3;
                        return command;
                    },
                }
            },
        }
    }

    return null;
}
