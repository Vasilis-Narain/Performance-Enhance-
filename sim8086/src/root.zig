const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

// Build comptime lookup table for bit counts 8 bit reg
// for parity flag.
fn buildBitCountTable8bit() [256]u8 {
    var table: [256]u8 = undefined;
    table[0] = 0;
    table[1] = 1;
    for (2..256) |i| {
        table[i] = table[i >> 1] + @as(u8, @intCast(i & 1));
    }
    return table;
}

// Don't need `comptime` keyword cause we GLOBAL (i.e. already comptime computed)
// Just do BitCountTable8bit[int n] to find how many bits are set for a given number (upto 255)
const BitCountTable8bit = buildBitCountTable8bit();

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

pub const effectiveAddress = enum(u8) {
    bx_si,
    bx_di,
    bp_si,
    bp_di,
    si,
    di,
    bp,
    bx,

    pub fn getStr(self: @This()) []const u8 {
        return addresses[@intFromEnum(self)];
    }
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
    registers: [10]u16 = .{0} ** 10,
    memory: [1024 * 1024]u8 = .{0} ** (1024 * 1024), // Maximum RAM for 8086 program

    pub const Registers = enum(u8) {
        ax,
        bx,
        cx,
        dx,
        sp,
        bp,
        si,
        di,
        ip,
        flags,
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

    const RegType = enum(u16) { lo = 0xFF00, hi = 0x00FF, full = 0x0000 };

    const Flags = enum(u4) {
        // Just add more here if needed (none more are needed, not all shall be implemented)
        C = 0,
        P = 2,
        A = 4,
        Z = 6,
        S = 7,
        T = 8,
        I = 9,
        D = 10,
        O = 11,
    };

    pub fn calculateEffectiveAddress(self: @This(), addr: effectiveAddress) u16 {
        return switch (addr) {
            .bx_si => self.registers[@intFromEnum(@as(Registers, .bx))] + self.registers[@intFromEnum(@as(Registers, .si))],
            .bx_di => self.registers[@intFromEnum(@as(Registers, .bx))] + self.registers[@intFromEnum(@as(Registers, .di))],
            .bp_si => self.registers[@intFromEnum(@as(Registers, .bp))] + self.registers[@intFromEnum(@as(Registers, .si))],
            .bp_di => self.registers[@intFromEnum(@as(Registers, .bp))] + self.registers[@intFromEnum(@as(Registers, .di))],
            .si => self.registers[@intFromEnum(@as(Registers, .si))],
            .di => self.registers[@intFromEnum(@as(Registers, .di))],
            .bp => self.registers[@intFromEnum(@as(Registers, .bp))],
            .bx => self.registers[@intFromEnum(@as(Registers, .bx))],
        };
    }

    pub fn setFlag(self: *@This(), flag: Flags, val: bool) void {
        const flag_u: u4 = @intFromEnum(flag);
        self.registers[self.registers.len - 1] = (self.registers[self.registers.len - 1] & ~(@as(u16, 1) << flag_u)) | (@as(u16, @intFromBool(val)) << flag_u);
    }

    pub fn isSetFlag(self: *const @This(), flag: Flags) bool {
        return (self.getRegisterVal(.flags) >> @intFromEnum(flag)) & 1 == 1;
    }

    pub fn printRegisters(self: *const @This(), writer: *Io.Writer) !void {
        try writer.print("\nFinal registers:\n", .{});
        var i: u8 = 0;
        while (i < @typeInfo(Registers).@"enum".fields.len - 1) : (i += 1) {
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
        try writer.print("\n", .{});
        try self.printSetFlags(writer);
        try writer.print("\n", .{});
    }

    pub fn printSetFlags(self: *const @This(), writer: *Io.Writer) !void {
        try writer.print("flags: ", .{});
        inline for (@typeInfo(Flags).@"enum".fields) |flag| {
            if (self.isSetFlag(@enumFromInt(flag.value))) try writer.print("{s}", .{flag.name});
        }
    }

    pub fn getRegisterVal(self: *const @This(), register: Registers) u16 {
        return self.registers[@intFromEnum(register)];
    }

    pub fn updateRegister(self: *@This(), register: Registers, new_val: u16, reg_type: RegType) void {
        // Disp derived from 0th bit of reg_type: only .hi has it set.
        const disp: u4 = @as(u4, @intCast(@intFromEnum(reg_type) & 1)) << 3; // NOTE: this shit = 8 bruh (or 0)
        self.registers[@intFromEnum(register)] = (self.registers[@intFromEnum(register)] & @intFromEnum(reg_type)) | (new_val << disp);
    }
    pub fn addToMemory(self: *@This(), address: u16, word: bool, new_val: u16, val_type: RegType) void {
        var lhs: u16 = undefined;
        if (!word) {
            lhs = @intCast(self.memory[address]);
        } else {
            const lhs_lo = self.memory[address];
            const lhs_hi = self.memory[address + 1];
            lhs = (@as(u16, @intCast(lhs_hi)) << 8) | @as(u16, @intCast(lhs_lo));
        }
        const rhs_sflag = switch (val_type) {
            .hi, .full => (new_val & 0x8000) == 0x8000,
            .lo => (new_val & 0x80) == 0x80,
        };
        var lhs_sflag: bool = undefined;
        var sum: u16 = undefined;
        var sum_sflag: bool = undefined;
        var aux_flag: bool = undefined;
        if (word) {
            lhs_sflag = (lhs & 0x8000) == 0x8000;
            sum = lhs +% new_val;
            sum_sflag = (sum & 0x8000) == 0x8000;
            aux_flag = ((lhs ^ new_val ^ sum) & 0x10) != 0;
            self.memory[address] = @truncate(sum & 0xFF);
            self.memory[address + 1] = @truncate((sum & 0xFF00) >> 8);
        } else {
            lhs_sflag = lhs & (@as(u16, @intCast(0x80))) == @as(u16, @intCast(0x80));
            const sum_8bit: u8 = @as(u8, @truncate(lhs)) +% @as(u8, @truncate(new_val));
            self.memory[address] = sum_8bit;
            aux_flag = ((@as(u8, @truncate(lhs)) ^ @as(u8, @truncate(new_val)) ^ sum_8bit) & 0x10) != 0;
            sum_sflag = (sum_8bit & 0x80) == 0x80;
            sum = @as(u16, @intCast(sum_8bit));
        }
        const parity = BitCountTable8bit[(sum & 0xFF)] % 2 == 0;
        self.setFlag(.S, sum_sflag);
        self.setFlag(.A, aux_flag);
        self.setFlag(.O, (lhs_sflag == rhs_sflag) and (lhs_sflag != sum_sflag));
        self.setFlag(.C, sum < new_val);
        self.setFlag(.Z, sum == 0);
        self.setFlag(.P, parity);
    }
    pub fn subToMemory(self: *@This(), address: u16, word: bool, new_val: u16, val_type: RegType, cmp_flag: bool) void {
        var lhs: u16 = undefined;
        if (!word) {
            lhs = @intCast(self.memory[address]);
        } else {
            const lhs_lo = self.memory[address];
            const lhs_hi = self.memory[address + 1];
            lhs = (@as(u16, @intCast(lhs_hi)) << 8) | @as(u16, @intCast(lhs_lo));
        }
        const rhs_sflag = switch (val_type) {
            .hi, .full => (new_val & 0x8000) == 0x8000,
            .lo => (new_val & 0x80) == 0x80,
        };
        var lhs_sflag: bool = undefined;
        var sum: u16 = undefined;
        var sum_sflag: bool = undefined;
        var aux_flag: bool = undefined;
        if (word) {
            lhs_sflag = (lhs & 0x8000) == 0x8000;
            sum = lhs -% new_val;
            sum_sflag = (sum & 0x8000) == 0x8000;
            aux_flag = ((lhs ^ new_val ^ sum) & 0x10) != 0;
            if (!cmp_flag) {
                self.memory[address] = @truncate(sum & 0xFF);
                self.memory[address + 1] = @truncate((sum & 0xFF00) >> 8);
            }
        } else {
            lhs_sflag = lhs & (@as(u16, @intCast(0x80))) == @as(u16, @intCast(0x80));
            const sum_8bit: u8 = @as(u8, @truncate(lhs)) -% @as(u8, @truncate(new_val));
            if (!cmp_flag) {
                self.memory[address] = sum_8bit;
            }
            aux_flag = ((@as(u8, @truncate(lhs)) ^ @as(u8, @truncate(new_val)) ^ sum_8bit) & 0x10) != 0;
            sum_sflag = (sum_8bit & 0x80) == 0x80;
            sum = @as(u16, @intCast(sum_8bit));
        }
        const parity = BitCountTable8bit[(sum & 0xFF)] % 2 == 0;
        self.setFlag(.S, sum_sflag);
        self.setFlag(.A, aux_flag);
        self.setFlag(.O, (lhs_sflag != rhs_sflag) and (lhs_sflag != sum_sflag));
        self.setFlag(.C, lhs < new_val);
        self.setFlag(.Z, sum == 0);
        self.setFlag(.P, parity);
    }
    pub fn addToRegister(self: *@This(), register: Registers, reg_type: RegType, new_val: u16, val_type: RegType) void {
        const disp: u4 = @as(u4, @intCast(@intFromEnum(reg_type) & 1)) << 3; // NOTE: yep, still 8 (or 0)
        const reg_val = self.registers[@intFromEnum(register)];
        const rhs_sflag = switch (val_type) {
            .hi, .full => (new_val & 0x8000) == 0x8000,
            .lo => (new_val & 0x80) == 0x80,
        };
        var lhs_sflag: bool = undefined;
        var sum: u16 = undefined;
        var sum_sflag: bool = undefined;
        var aux_flag: bool = undefined;
        switch (reg_type) {
            .full => {
                lhs_sflag = (reg_val & 0x8000) == 0x8000;
                sum = reg_val +% new_val;
                sum_sflag = (sum & 0x8000) == 0x8000;
                aux_flag = ((reg_val ^ new_val ^ sum) & 0x10) != 0;
            },
            .hi, .lo => {
                lhs_sflag = (reg_val & (@as(u16, @intCast(0x80)) << disp)) == @as(u16, @intCast(0x80)) << disp;
                const sum_8bit: u8 = @as(u8, @truncate(reg_val >> disp)) +% @as(u8, @truncate(new_val));
                aux_flag = ((@as(u8, @truncate(reg_val >> disp)) ^ @as(u8, @truncate(new_val)) ^ sum_8bit) & 0x10) != 0;
                sum_sflag = (sum_8bit & 0x80) == 0x80;
                sum = @as(u16, @intCast(sum_8bit)) << disp;
            },
        }
        sum &= ~@intFromEnum(reg_type);
        const parity = BitCountTable8bit[(sum & 0xFF)] % 2 == 0;
        self.setFlag(.S, sum_sflag);
        self.setFlag(.A, aux_flag);
        self.setFlag(.O, (lhs_sflag == rhs_sflag) and (lhs_sflag != sum_sflag));
        self.setFlag(.C, sum < new_val);
        self.setFlag(.Z, sum == 0);
        self.setFlag(.P, parity);
        self.updateRegister(register, sum, reg_type);
    }

    fn sub(self: *@This(), register: Registers, reg_type: RegType, new_val: u16, val_type: RegType) u16 {
        const disp: u4 = @as(u4, @intCast(@intFromEnum(reg_type) & 1)) << 3; // NOTE: yep, still 8 (or 0)
        var reg_val = self.registers[@intFromEnum(register)];
        const rhs_sflag = switch (val_type) {
            .hi, .full => (new_val & 0x8000) == 0x8000,
            .lo => (new_val & 0x80) == 0x80,
        };
        var lhs_sflag: bool = undefined;
        var diff: u16 = undefined;
        var diff_sflag: bool = undefined;
        var aux_flag: bool = undefined;
        switch (reg_type) {
            .full => {
                lhs_sflag = (reg_val & 0x8000) == 0x8000;
                //af = ((a ^ b ^ result) & 0x10) != 0;
                diff = reg_val -% new_val;
                aux_flag = ((reg_val ^ new_val ^ diff) & 0x10) != 0;
                diff_sflag = (diff & 0x8000) == 0x8000;
            },
            .hi, .lo => {
                lhs_sflag = (reg_val & (@as(u16, @intCast(0x80)) << disp)) == @as(u16, @intCast(0x80)) << disp;
                reg_val >>= disp;
                const diff_8bit: u8 = @as(u8, @truncate(reg_val)) -% @as(u8, @truncate(new_val));
                aux_flag = ((@as(u8, @truncate(reg_val)) ^ @as(u8, @truncate(new_val)) ^ diff_8bit) & 0x10) != 0;
                diff_sflag = (diff_8bit & 0x80) == 0x80;
                diff = @as(u16, @intCast(diff_8bit)) << disp;
            },
        }
        diff &= ~@intFromEnum(reg_type);
        const parity = BitCountTable8bit[(diff & 0xFF)] % 2 == 0;
        self.setFlag(.S, diff_sflag);
        self.setFlag(.A, aux_flag);
        self.setFlag(.O, (lhs_sflag != rhs_sflag) and (lhs_sflag != diff_sflag));
        self.setFlag(.C, reg_val < new_val);
        self.setFlag(.Z, diff == 0);
        self.setFlag(.P, parity);
        return diff;
    }

    pub fn subToRegister(self: *@This(), register: Registers, reg_type: RegType, new_val: u16, val_type: RegType) void {
        self.registers[@intFromEnum(register)] = self.sub(register, reg_type, new_val, val_type);
    }
    pub fn cmp(self: *@This(), register: Registers, reg_type: RegType, new_val: u16, val_type: RegType) void {
        _ = self.sub(register, reg_type, new_val, val_type);
    }

    pub fn execute(self: *@This(), command: *const Command) !void {
        const ip_type: Registers = .ip;
        var writer = Io.Writer.fixed(&self.printBuf);
        if (command.jump_op) |jmp_op| {
            const ip_idx = @intFromEnum(@as(Registers, .ip));
            const disp: i16 = @as(i8, @bitCast(@as(u8, @truncate(command.data.?))));
            const taken = switch (jmp_op) {
                .jnz => !self.isSetFlag(.Z),
                else => unreachable,
            };
            if (taken) self.registers[ip_idx] +%= @bitCast(disp);
            return;
        }
        try writer.print("; ip: 0x{x}", .{self.registers[@intFromEnum(ip_type)]});
        if (command.partial_opcode) |partial_opcode| {
            switch (partial_opcode) {
                .mov_rtr => {
                    const diff: u8 = if (command.w.? == 1) 0 else 8;
                    var reg_8: Registers_8bit = undefined;
                    var reg: Registers = undefined;
                    var reg_type: RegType = .full;
                    const mod = command.mod.?;
                    switch (mod) {
                        // Register mode
                        0b00000011 => {
                            var rm_type: RegType = .full;
                            var rm_8: Registers_8bit = undefined;
                            var rm: Registers = undefined;
                            if (diff > 0) {
                                reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                rm_8 = std.meta.stringToEnum(Registers_8bit, registers[command.rm.?]).?;
                                reg = reg_8.getRegister16bit();
                                rm = rm_8.getRegister16bit();
                                if (@intFromEnum(reg_8) < 4) {
                                    reg_type = .hi;
                                } else reg_type = .lo;
                                if (@intFromEnum(rm_8) < 4) {
                                    rm_type = .hi;
                                } else rm_type = .lo;
                            } else {
                                reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                rm = std.meta.stringToEnum(Registers, registers[command.rm.?]).?;
                            }
                            const prev_data = self.getRegisterVal(reg);
                            var data: u16 = self.getRegisterVal(rm);
                            if (rm_type == .hi) {
                                data >>= 8;
                            }
                            self.updateRegister(reg, data, reg_type);
                            try writer.print(" {s}: 0x{x}->0x{x}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                        },
                        // Memory Modes
                        // no disp (or direct addr if rm = 110)
                        0b00 => {
                            const d = command.d.?;
                            if (command.rm.? == 0b110) {
                                const expl_addr = command.expl_addr.?;
                                var data: u16 = undefined;
                                if (diff == 0) {
                                    reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                    data = self.getRegisterVal(reg);
                                    const data_lo = if (d == 1) self.memory[expl_addr] else @as(u8, @truncate(data & 0xFF));
                                    const data_hi = if (d == 1) self.memory[expl_addr + 1] else @as(u8, @truncate((data & 0xFF00) >> 8));
                                    if (d == 1) {
                                        data = (@as(u16, @intCast(data_hi)) << 8) | data_lo;
                                    } else {
                                        self.memory[expl_addr] = data_lo;
                                        self.memory[expl_addr + 1] = data_hi;
                                    }
                                } else {
                                    reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                    reg = reg_8.getRegister16bit();
                                    if (@intFromEnum(reg_8) < 4) {
                                        reg_type = .hi;
                                    } else reg_type = .lo;
                                    if (d == 1) {
                                        data = @intCast(self.memory[expl_addr]);
                                    } else {
                                        var data_u8: u8 = undefined;
                                        data = self.getRegisterVal(reg);
                                        if (@intFromEnum(reg_8) < 4) {
                                            data_u8 = @truncate((data & 0xFF00) >> 8);
                                        } else data_u8 = @truncate(data & 0xFF);
                                        self.memory[expl_addr] = data_u8;
                                    }
                                }
                                if (d == 1) {
                                    const prev_data = self.getRegisterVal(reg);
                                    self.updateRegister(reg, data, reg_type);
                                    try writer.print(" {s}: 0x{x}->0x{x}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                }
                            } else {
                                const effective_addr = self.calculateEffectiveAddress(command.addr.?);
                                var data: u16 = undefined;
                                if (d == 1) {
                                    if (diff == 0) {
                                        reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                        const data_lo = self.memory[effective_addr];
                                        const data_hi = self.memory[effective_addr + 1];
                                        data = (@as(u16, @intCast(data_hi)) << 8) | data_lo;
                                    } else {
                                        reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                        reg = reg_8.getRegister16bit();
                                        if (@intFromEnum(reg_8) < 4) {
                                            reg_type = .hi;
                                        } else reg_type = .lo;
                                        data = @intCast(self.memory[effective_addr]);
                                    }
                                    const prev_data = self.getRegisterVal(reg);
                                    self.updateRegister(reg, data, reg_type);
                                    try writer.print(" {s}: 0x{x}->0x{x}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                } else {
                                    if (diff == 0) {
                                        reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                        data = self.getRegisterVal(reg);
                                        const data_lo: u8 = @truncate(data & 0xFF);
                                        const data_hi: u8 = @truncate((data & 0xFF00) >> 8);
                                        self.memory[effective_addr] = data_lo;
                                        self.memory[effective_addr + 1] = data_hi;
                                    } else {
                                        reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                        reg = reg_8.getRegister16bit();
                                        data = self.getRegisterVal(reg);
                                        var data_u8: u8 = undefined;
                                        if (@intFromEnum(reg_8) < 4) {
                                            data_u8 = @truncate((data & 0xFF00) >> 8);
                                        } else data_u8 = @truncate(data & 0xFF);
                                        self.memory[effective_addr] = data_u8;
                                    }
                                }
                            }
                        },
                        // 8 bit disp
                        0b01 => {
                            const d = command.d.?;
                            var effective_addr = self.calculateEffectiveAddress(command.addr.?);
                            const disp = command.displacement_8.?;
                            var data: u16 = undefined;
                            effective_addr = if (disp < 0) effective_addr -% @as(u16, (@abs(disp))) else effective_addr +% @as(u16, (@abs(disp)));
                            if (diff == 0) {
                                reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                data = self.getRegisterVal(reg);
                                const data_lo = if (d == 1) self.memory[effective_addr] else @as(u8, @truncate(data & 0xFF));
                                const data_hi = if (d == 1) self.memory[effective_addr + 1] else @as(u8, @truncate((data & 0xFF00) >> 8));
                                if (d == 1) {
                                    data = (@as(u16, @intCast(data_hi)) << 8) | data_lo;
                                } else {
                                    self.memory[effective_addr] = data_lo;
                                    self.memory[effective_addr + 1] = data_hi;
                                }
                            } else {
                                reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                reg = reg_8.getRegister16bit();
                                if (@intFromEnum(reg_8) < 4) {
                                    reg_type = .hi;
                                } else reg_type = .lo;
                                if (d == 1) {
                                    data = @intCast(self.memory[effective_addr]);
                                } else {
                                    var data_u8: u8 = undefined;
                                    data = self.getRegisterVal(reg);
                                    if (@intFromEnum(reg_8) < 4) {
                                        data_u8 = @truncate((data & 0xFF00) >> 8);
                                    } else data_u8 = @truncate(data & 0xFF);
                                    self.memory[effective_addr] = data_u8;
                                }
                            }
                            if (d == 1) {
                                const prev_data = self.getRegisterVal(reg);
                                self.updateRegister(reg, data, reg_type);
                                try writer.print(" {s}: 0x{x}->0x{x}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                            }
                        },
                        // 16 bit disp
                        0b10 => {},
                        else => {},
                    }
                },
                .mov_itm => {
                    const mod = command.mod.?;
                    const rm = command.rm.?;
                    const data = command.data.?;
                    const w = command.w.?;
                    const s = command.s.?;
                    switch (mod) {

                        // Memory Mode 00 no disp except R/M = 110
                        0b00 => {
                            // Normal no disp
                            if (rm != 0b00000110) {} else { // explicit address
                                const expl_addr = command.expl_addr.?;
                                if (s == 0 and w == 1) {
                                    const data_hi: u8 = @truncate(data >> 8);
                                    const data_lo: u8 = @truncate(data);
                                    self.memory[expl_addr] = data_lo;
                                    self.memory[expl_addr + 1] = data_hi;
                                } else {
                                    const data_u8: u8 = @truncate(data);
                                    self.memory[expl_addr] = data_u8;
                                }
                            }
                        },

                        // 8bit disp
                        0b01 => {
                            var effective_addr = self.calculateEffectiveAddress(command.addr.?);
                            const disp = command.displacement_8.?;
                            effective_addr = if (disp < 0) effective_addr -% @as(u16, (@abs(disp))) else effective_addr +% @as(u16, (@abs(disp)));
                            if (w == 1) {
                                const data_hi: u8 = @truncate(data >> 8);
                                const data_lo: u8 = @truncate(data);
                                self.memory[effective_addr] = data_lo;
                                self.memory[effective_addr + 1] = data_hi;
                            } else {
                                const data_u8: u8 = @truncate(data);
                                self.memory[effective_addr] = data_u8;
                            }
                        },
                        // Memory Mode 01, 8-bit displacement follows
                        //  also Memory Mode 10, 16-bit displacement follows
                        0b10 => {},
                        else => unreachable,
                    }
                },
                .mov_xtra => {
                    const mov_type = command.mov_xtra_type.?;
                    const diff: u8 = if (command.w.? == 1) 0 else 8;
                    var reg_8: Registers_8bit = undefined;
                    var reg: Registers = undefined;
                    var reg_type: RegType = .full;
                    if (diff > 0) {
                        reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                        reg = reg_8.getRegister16bit();
                        if (@intFromEnum(reg_8) < 4) {
                            reg_type = .hi;
                        } else reg_type = .lo;
                    } else {
                        reg = std.meta.stringToEnum(Registers, registers[command.reg.? + diff]).?;
                    }

                    switch (mov_type) {
                        .itr => {
                            const prev_data = self.getRegisterVal(reg);
                            self.updateRegister(reg, command.data.?, reg_type);
                            try writer.print(" {s}: 0x{x}->0x{x}", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                        },
                        .atm => {},
                        .mta => {},
                    }
                },
                .add_rtr, .sub_rtr, .cmp_rtr => {
                    const op_type = command.itm_op.?;
                    const is_wide_reg = command.w.? == 1;
                    const is_wide_data: RegType = if (is_wide_reg) .full else .lo;
                    const diff: u8 = if (is_wide_reg) 0 else 8;
                    var reg_8: Registers_8bit = undefined;
                    var rm_8: Registers_8bit = undefined;
                    var reg: Registers = undefined;
                    var rm: Registers = undefined;
                    var reg_type: RegType = .full;
                    switch (command.mod.?) {
                        0b11 => {
                            if (diff > 0) {
                                reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                rm_8 = std.meta.stringToEnum(Registers_8bit, registers[command.rm.?]).?;
                                reg = reg_8.getRegister16bit();
                                rm = reg_8.getRegister16bit();
                                if (@intFromEnum(reg_8) < 4) {
                                    reg_type = .hi;
                                } else reg_type = .lo;
                            } else {
                                reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                rm = std.meta.stringToEnum(Registers, registers[command.rm.?]).?;
                            }
                            const prev_data = self.getRegisterVal(reg);
                            const new_data = self.getRegisterVal(rm);
                            switch (op_type) {
                                .add => {
                                    self.addToRegister(reg, reg_type, new_data, is_wide_data);
                                    try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                },
                                .sub => {
                                    self.subToRegister(reg, reg_type, new_data, is_wide_data);
                                    try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                },
                                .cmp => {
                                    self.cmp(reg, reg_type, new_data, is_wide_data);
                                },
                                else => unreachable,
                            }
                            try self.printSetFlags(&writer);
                        },
                        // Memory Modes
                        // no disp (or direct addr if rm = 110)
                        0b00 => {
                            if (command.rm.? == 0b110) {
                                const expl_addr = command.expl_addr.?;
                                var data: u16 = undefined;
                                if (diff == 0) {
                                    reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                    const data_lo = self.memory[expl_addr];
                                    const data_hi = self.memory[expl_addr + 1];
                                    data = (@as(u16, @intCast(data_hi)) << 8) | data_lo;
                                } else {
                                    reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                    reg = reg_8.getRegister16bit();
                                    if (@intFromEnum(reg_8) < 4) {
                                        reg_type = .hi;
                                    } else reg_type = .lo;
                                    data = @intCast(self.memory[expl_addr]);
                                }
                                const prev_data = self.getRegisterVal(reg);
                                switch (op_type) {
                                    .add => {
                                        self.addToRegister(reg, reg_type, data, is_wide_data);
                                        try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                    },
                                    .sub => {
                                        self.subToRegister(reg, reg_type, data, is_wide_data);
                                        try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                    },
                                    .cmp => {
                                        self.cmp(reg, reg_type, data, is_wide_data);
                                    },
                                    else => unreachable,
                                }
                                try self.printSetFlags(&writer);
                            } else {
                                const d = command.d.?;
                                const effective_addr = self.calculateEffectiveAddress(command.addr.?);
                                var data: u16 = undefined;
                                if (d == 1) {
                                    if (diff == 0) {
                                        reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                        const data_lo = self.memory[effective_addr];
                                        const data_hi = self.memory[effective_addr + 1];
                                        data = (@as(u16, @intCast(data_hi)) << 8) | data_lo;
                                    } else {
                                        reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                        reg = reg_8.getRegister16bit();
                                        if (@intFromEnum(reg_8) < 4) {
                                            reg_type = .hi;
                                        } else reg_type = .lo;
                                        data = @intCast(self.memory[effective_addr]);
                                    }
                                    const prev_data = self.getRegisterVal(reg);
                                    switch (op_type) {
                                        .add => {
                                            self.addToRegister(reg, reg_type, data, is_wide_data);
                                            try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                        },
                                        .sub => {
                                            self.subToRegister(reg, reg_type, data, is_wide_data);
                                            try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                        },
                                        .cmp => {
                                            self.cmp(reg, reg_type, data, is_wide_data);
                                        },
                                        else => unreachable,
                                    }
                                    try self.printSetFlags(&writer);
                                } else {
                                    if (diff == 0) {
                                        reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                        data = self.getRegisterVal(reg);
                                        try self.printSetFlags(&writer);

                                        switch (op_type) {
                                            .add => {
                                                self.addToMemory(effective_addr, true, data, is_wide_data);
                                            },
                                            .sub => {
                                                self.subToMemory(effective_addr, true, data, is_wide_data, false);
                                            },
                                            .cmp => {
                                                self.subToMemory(effective_addr, true, data, is_wide_data, true);
                                            },
                                            else => unreachable,
                                        }
                                    } else {
                                        reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                        reg = reg_8.getRegister16bit();
                                        data = self.getRegisterVal(reg);
                                        var data_u8: u8 = undefined;
                                        if (@intFromEnum(reg_8) < 4) {
                                            data_u8 = @truncate((data & 0xFF00) >> 8);
                                        } else data_u8 = @truncate(data & 0xFF);
                                        switch (op_type) {
                                            .add => {
                                                self.addToMemory(effective_addr, false, data, is_wide_data);
                                            },
                                            .sub => {
                                                self.subToMemory(effective_addr, false, data, is_wide_data, false);
                                            },
                                            .cmp => {
                                                self.subToMemory(effective_addr, false, data, is_wide_data, true);
                                            },
                                            else => unreachable,
                                        }
                                    }
                                }
                            }
                        },
                        // 8 bit disp
                        // TODO: make sure this works in both directions (d, like above)
                        0b01 => {
                            var effective_addr = self.calculateEffectiveAddress(command.addr.?);
                            const disp = command.displacement_8.?;
                            var data: u16 = undefined;
                            effective_addr = if (disp < 0) effective_addr -% @as(u16, (@abs(disp))) else effective_addr +% @as(u16, (@abs(disp)));
                            if (diff == 0) {
                                reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                                const data_lo = self.memory[effective_addr];
                                const data_hi = self.memory[effective_addr + 1];
                                data = (@as(u16, @intCast(data_hi)) << 8) | data_lo;
                            } else {
                                reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                reg = reg_8.getRegister16bit();
                                if (@intFromEnum(reg_8) < 4) {
                                    reg_type = .hi;
                                } else reg_type = .lo;
                                data = @intCast(self.memory[effective_addr]);
                            }
                            const prev_data = self.getRegisterVal(reg);
                            self.addToRegister(reg, reg_type, data, reg_type);
                            try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                            try self.printSetFlags(&writer);
                        },
                        // 16 bit disp
                        0b10 => {},
                        else => unreachable,
                    }
                },
                //.sub_rtr => {
                //const is_wide_reg = command.w.? == 1;
                //const is_wide_data: RegType = if (is_wide_reg) .full else .lo;
                //const diff: u8 = if (is_wide_reg) 0 else 8;
                //var reg_8: Registers_8bit = undefined;
                //var rm_8: Registers_8bit = undefined;
                //var reg: Registers = undefined;
                //var rm: Registers = undefined;
                //var reg_type: RegType = .full;
                //if (diff > 0) {
                //reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                //rm_8 = std.meta.stringToEnum(Registers_8bit, registers[command.rm.?]).?;
                //reg = reg_8.getRegister16bit();
                //rm = reg_8.getRegister16bit();
                //if (@intFromEnum(reg_8) < 4) {
                //reg_type = .hi;
                //} else reg_type = .lo;
                //} else {
                //reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                //rm = std.meta.stringToEnum(Registers, registers[command.rm.?]).?;
                //}
                //const prev_data = self.getRegisterVal(reg);
                //const subtraction_data = self.getRegisterVal(rm);
                //self.subToRegister(reg, reg_type, subtraction_data, is_wide_data);
                //try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                //try self.printSetFlags(&writer);
                //},
                //.cmp_rtr => {
                //const is_wide_reg = command.w.? == 1;
                //const is_wide_data: RegType = if (is_wide_reg) .full else .lo;
                //const diff: u8 = if (is_wide_reg) 0 else 8;
                //var reg_8: Registers_8bit = undefined;
                //var rm_8: Registers_8bit = undefined;
                //var reg: Registers = undefined;
                //var rm: Registers = undefined;
                //var reg_type: RegType = .full;
                //if (diff > 0) {
                //reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                //rm_8 = std.meta.stringToEnum(Registers_8bit, registers[command.rm.?]).?;
                //reg = reg_8.getRegister16bit();
                //rm = reg_8.getRegister16bit();
                //if (@intFromEnum(reg_8) < 4) {
                //reg_type = .hi;
                //} else reg_type = .lo;
                //} else {
                //reg = std.meta.stringToEnum(Registers, registers[command.reg.?]).?;
                //rm = std.meta.stringToEnum(Registers, registers[command.rm.?]).?;
                //}
                //const subtraction_data = self.getRegisterVal(rm);
                //self.cmp(reg, reg_type, subtraction_data, is_wide_data);
                //try writer.print(" ", .{});
                //try self.printSetFlags(&writer);
                //},
                .arithmetic_itm => {
                    //const ItmOp = enum(u8) {
                    //add = 0b00000000,
                    //adc = 0b00000010,
                    //sub = 0b00000101,
                    //cmp = 0b00000111,
                    //};
                    switch (command.mod.?) {
                        0b11 => {
                            const is_wide_reg = command.w.? == 1;
                            const is_wide_data: RegType = if (is_wide_reg and command.s.? == 0) .full else .lo;
                            const diff: u8 = if (is_wide_reg) 0 else 8;
                            var reg_8: Registers_8bit = undefined;
                            var reg: Registers = undefined;
                            var reg_type: RegType = .full;
                            if (diff > 0) {
                                reg_8 = std.meta.stringToEnum(Registers_8bit, registers[command.reg.?]).?;
                                reg = reg_8.getRegister16bit();
                                if (@intFromEnum(reg_8) < 4) {
                                    reg_type = .hi;
                                } else reg_type = .lo;
                            } else {
                                reg = std.meta.stringToEnum(Registers, registers[command.reg.? + 8]).?;
                            }
                            const prev_data = self.getRegisterVal(reg);
                            switch (command.itm_op.?) {
                                .add => {
                                    self.addToRegister(reg, reg_type, command.data.?, is_wide_data);
                                    try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                    try self.printSetFlags(&writer);
                                },
                                .sub => {
                                    self.subToRegister(reg, reg_type, command.data.?, is_wide_data);
                                    try writer.print(" {s}: 0x{x}->0x{x} ", .{ @tagName(reg), prev_data, self.getRegisterVal(reg) });
                                    try self.printSetFlags(&writer);
                                },
                                .cmp => {
                                    self.cmp(reg, reg_type, command.data.?, is_wide_data);
                                    try self.printSetFlags(&writer);
                                },
                                else => unreachable,
                            }
                        },
                        else => {},
                    }
                },

                else => return,
            }
        }
        self.printString = writer.buffered();
    }

    pub fn resetBuffers(self: *@This()) void {
        self.printBuf = undefined;
        self.printString = &.{};
    }
};

pub const Command = struct {
    partial_opcode: ?Op = null,
    itm_op: ?ItmOp = null,
    jump_op: ?JumpOp = null,
    addr: ?effectiveAddress = null,
    expl_addr: ?u16 = null,
    reg: ?u8 = null,
    rm: ?u8 = null,
    data: ?u16 = null,
    mod: ?u8 = null,
    displacement_8: ?i8 = null,
    displacement_16: ?i16 = null,
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
pub fn disassemble(buf: [6]u8, buf_pos: *u8, command: *Command) Io.Writer.Error!bool {
    assert(buf_pos.* == 0);
    while (buf_pos.* + 1 < buf.len) {
        const buf_i = buf[buf_pos.*];
        // Check for jumps
        const jump: JumpOp = @enumFromInt(buf_i);
        var writer: std.Io.Writer = .fixed(&command.commandBuf);
        switch (jump) {
            _ => {},
            else => {
                const jump_str = @tagName(jump);
                const data: i8 = @bitCast(buf[buf_pos.* + 1]);
                command.negative = if (data < 0) true else false;
                command.data = buf[buf_pos.* + 1];
                command.jump_op = jump;
                buf_pos.* += 2;
                try writer.print("{s} ($+2)+{d}", .{ jump_str, data });
                command.command = writer.buffered();
                return true;
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
                var itm_op: ?ItmOp = null;
                switch (op) {
                    .mov_rtr => {},
                    .add_rtr => itm_op = .add,
                    .sub_rtr => itm_op = .sub,
                    .cmp_rtr => itm_op = .cmp,
                    .adc_rtr => itm_op = .adc,
                    else => unreachable,
                }
                command.itm_op = itm_op;
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
                        return true;
                    },

                    // Memory Mode 00 no displacement (except for rm 110 dir addr)
                    0b00000000 => {
                        command.rm = rm;
                        command.reg = reg + w * 8;
                        if (rm != 0b00000110) {
                            const eff_addr = addresses[rm];
                            if (d == 1) {
                                try writer.print("{s}, [{s}]", .{ reg_str, eff_addr });
                            } else {
                                try writer.print("[{s}], {s}", .{ eff_addr, reg_str });
                            }
                            command.addr = @as(effectiveAddress, @enumFromInt(rm));
                            command.command = writer.buffered();
                            buf_pos.* += 2;
                            return true;
                        } else {
                            const word = if (w == 1) "word" else "byte";
                            const data_lo: u16 = @intCast(buf[buf_pos.* + 2]);
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            const data: u16 = (data_hi << 8) | data_lo;
                            command.expl_addr = data;
                            try writer.print("{s}, {s} [{d}]", .{ reg_str, word, data });
                            command.command = writer.buffered();
                            buf_pos.* += 4;
                            return true;
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

                        command.reg = reg + w * 8;
                        command.addr = @as(effectiveAddress, @enumFromInt(rm));

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
                        }
                        command.displacement_8 = data;
                        command.command = writer.buffered();
                        buf_pos.* += 3;
                        return true;
                    },

                    // Memory Mode 10, 16-bit displacement follows
                    0b00000010 => {
                        const eff_addr = addresses[rm];
                        const data_lo: u16 = @intCast(buf[buf_pos.* + 2]);
                        const data_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                        var data: i16 = @bitCast((data_hi << 8) | data_lo);
                        const neg = if (data >= 0) false else true;
                        const sign = if (!neg) "+" else "-";
                        command.reg = reg + w * 8;
                        command.addr = @as(effectiveAddress, @enumFromInt(rm));
                        if (data < 0) data *= -1;
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
                        }
                        command.displacement_16 = data;
                        command.command = writer.buffered();
                        buf_pos.* += 4;
                        return true;
                    },

                    else => unreachable,
                }
            },
            // Immediate-to-register/memory
            // mov, add/sub/cmp
            .mov_itm, .arithmetic_itm => {
                const itm_op: ItmOp = @enumFromInt((buf[buf_pos.* + 1] >> 3) & 0b00000111);
                if (op != .mov_itm) command.itm_op = itm_op;
                const op_str = if (op == .mov_itm) "mov" else @tagName(itm_op);
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
                            command.addr = @as(effectiveAddress, @enumFromInt(rm));
                            command.command = writer.buffered();
                            return true;
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
                            return true;
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
                        command.reg = rm;
                        command.data = data;
                        command.command = writer.buffered();
                        return true;
                    },

                    // Memory Mode 01, 8-bit displacement follows
                    //  also Memory Mode 10, 16-bit displacement follows
                    0b00000001, 0b00000010 => {
                        const eff_addr = addresses[rm];
                        var disp_16: i16 = undefined;
                        var disp_8: i8 = undefined;
                        var disp_u16: u16 = @intCast(buf[buf_pos.* + 2]);
                        var disp_neg: bool = false;
                        var disp_0: bool = false;

                        if (mod == 0b00000010) {
                            const disp_hi: u16 = @intCast(buf[buf_pos.* + 3]);
                            disp_u16 |= disp_hi << 8;
                            disp_16 = @bitCast((disp_hi << 8) | disp_u16);
                            if (disp_16 < 0) disp_neg = true;
                            if (disp_16 == 0) disp_0 = true;
                            command.displacement_16 = disp_16;
                            buf_pos.* += 1;
                        } else {
                            disp_8 = @bitCast(@as(u8, @truncate(disp_u16)));
                            command.displacement_8 = disp_8;
                            disp_16 = @intCast(disp_8);
                            if (disp_8 < 0) disp_neg = true;
                            if (disp_8 == 0) disp_0 = true;
                        }

                        const sign = if (!disp_neg) "+" else "-";

                        var data: u16 = @intCast(buf[buf_pos.* + 3]);
                        if (s == 0 and w == 1) {
                            const data_hi: u16 = @intCast(buf[buf_pos.* + 4]);
                            data = (data_hi << 8) | data;
                            buf_pos.* += 5;
                        } else {
                            buf_pos.* += 4;
                        }
                        try writer.print("{s} ", .{w_keyword});
                        if (disp_0) {
                            try writer.print("[{s}], ", .{eff_addr});
                        } else {
                            try writer.print("[{s} {s} {d}], ", .{ eff_addr, sign, @abs(disp_16) });
                        }
                        try writer.print("{d}", .{data});

                        command.addr = @as(effectiveAddress, @enumFromInt(rm));
                        command.neg_displ = disp_neg;
                        command.data = data;
                        command.command = writer.buffered();
                        return true;
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
                return true;
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
                        return true;
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
                        return true;
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
                        return true;
                    },
                }
            },
        }
    }

    return false;
}
