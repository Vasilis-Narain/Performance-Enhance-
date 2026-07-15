//* TODO(vasilis): figure out how to avoid all heap allocations (need a LIFO idea for parent tracking)
const std = @import("std");
const metrics = @import("metrics.zig");

// ANSI color escape sequences
const ANSI_RESET = "\x1b[0m";
const ANSI_RED = "\x1b[31m";
const ANSI_GREEN = "\x1b[32m";
const ANSI_YELLOW = "\x1b[33m";

const MAX_TRACE_SIZE: u8 = 255;

const Bitset = std.StaticBitSet(MAX_TRACE_SIZE);

pub const ProfilerInstance = struct {
    trace_stack: [MAX_TRACE_SIZE]*Trace,
    fn_trace_stack: [MAX_TRACE_SIZE]Trace,
    current: ?*Trace,
    start_tick: u64,
    trace_count: u8,
    fn_trace_count: u8,
    allocator: std.mem.Allocator,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .trace_stack = undefined,
            .fn_trace_stack = undefined,
            .fn_trace_count = 0,
            .trace_count = 0,
            .start_tick = metrics.readCpuTimer(),
            .current = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        var i: u8 = 0;
        while (i < self.trace_count) : (i += 1) {
            self.allocator.destroy(self.trace_stack[i]);
        }
    }

    pub fn print(self: *const @This(), writer: *std.Io.Writer) !void {
        const process_elapsed = metrics.readCpuTimer() - self.start_tick;
        try writer.print(
            \\{s}
            \\  ===========================================
            \\                PROFILER STATS
            \\  ===========================================
            \\{s}
            \\ | {s}Traces{s}:
            \\
        , .{ ANSI_GREEN, ANSI_RESET, ANSI_YELLOW, ANSI_RESET });
        var i: u8 = 0;
        while (i < self.trace_count) : (i += 1) {
            try writer.print(" |  {s}::{s}[{d}:{d}]: {s}{s}{s} => elapsed: {d} ({d:.2}%)\n", .{
                self.trace_stack[i].src.file,
                self.trace_stack[i].src.fn_name,
                self.trace_stack[i].src.line,
                self.trace_stack[i].src.column,
                ANSI_GREEN,
                self.trace_stack[i].name,
                ANSI_RESET,
                self.trace_stack[i].elapsed_tick,
                percentageWorkDone(self.trace_stack[i].elapsed_tick, process_elapsed),
            });
        }
        try writer.print(" |\n | {s}Function traces:{s}\n", .{ ANSI_YELLOW, ANSI_RESET });
        i = 0;
        while (i < self.fn_trace_count) : (i += 1) {
            try writer.print(" |  {s}::{s}{s}{s}[{d}:{d}] => elapsed: {d} ({d:.2}%)\n", .{
                self.fn_trace_stack[i].src.file,
                ANSI_GREEN,
                self.fn_trace_stack[i].name,
                ANSI_RESET,
                self.fn_trace_stack[i].src.line,
                self.fn_trace_stack[i].src.column,
                self.fn_trace_stack[i].elapsed_tick,
                percentageWorkDone(self.fn_trace_stack[i].elapsed_tick, process_elapsed),
            });
        }
        try writer.print(" |\n | Total elapsed: {d} / {d:.4}ms\n\n", .{
            process_elapsed,
            @as(f64, @floatFromInt(process_elapsed)) / @as(f64, @floatFromInt(metrics.readCpuTimerFreq())) * 1000,
        });
    }
};

pub const Trace = struct {
    start_tick: u64,
    end_tick: u64,
    elapsed_tick: u64,
    elapsed_tick_from_child: u64,
    name: []const u8,
    src: std.builtin.SourceLocation,
    profiler: *ProfilerInstance,
    parent: ?*@This(),

    pub fn init(profiler_instance_ptr: *ProfilerInstance, comptime name: []const u8, comptime src: std.builtin.SourceLocation) !*@This() {
        const pf = profiler_instance_ptr;
        const self = try pf.allocator.create(@This());
        errdefer pf.allocator.destroy(self);

        if (pf.trace_count >= pf.trace_stack.len) return error.TooManyTraces;

        self.* = .{
            .start_tick = metrics.readCpuTimer(),
            .end_tick = undefined,
            .elapsed_tick = 0,
            .elapsed_tick_from_child = 0,
            .name = name,
            .src = src,
            .profiler = pf,
            .parent = pf.current,
        };
        pf.trace_stack[pf.trace_count] = self;
        pf.trace_count += 1;
        pf.current = self;

        return self;
    }

    pub fn stop(self: *@This()) void {
        self.end_tick = metrics.readCpuTimer();
        // Note(vasilis): this feels like it should be strictly positive so I am gonna assume it is
        self.elapsed_tick = (self.end_tick - self.start_tick) - self.elapsed_tick_from_child;

        if (self.parent) |parent| {
            parent.elapsed_tick_from_child += self.elapsed_tick;
        }
        self.profiler.current = self.parent;
    }

    pub fn initFnTrace(profiler_instance_ptr: *ProfilerInstance, comptime src: std.builtin.SourceLocation) *@This() {
        const pf = profiler_instance_ptr;

        const S = struct {
            const _tag = src;
            var idx: u32 = std.math.maxInt(u32);
        };

        if (S.idx != std.math.maxInt(u32)) {
            const trace = &pf.fn_trace_stack[S.idx];
            trace.start_tick = metrics.readCpuTimer();
            trace.end_tick = undefined;
            return trace;
        }

        const i = pf.fn_trace_count;
        std.debug.assert(i < pf.fn_trace_stack.len);

        const self: Trace = .{
            .start_tick = metrics.readCpuTimer(),
            .end_tick = undefined,
            .elapsed_tick = 0,
            .elapsed_tick_from_child = 0,
            .name = src.fn_name,
            .src = src,
            .profiler = pf,
            .parent = null,
        };

        pf.fn_trace_stack[i] = self;
        pf.fn_trace_count += 1;
        S.idx = i;
        return &pf.fn_trace_stack[S.idx];
    }

    pub fn updateFnTrace(self: *@This()) void {
        self.end_tick = metrics.readCpuTimer();
        self.elapsed_tick += self.end_tick - self.start_tick;
    }
};

fn percentageWorkDone(work_elapsed: u64, process_elapsed: u64) f64 {
    return (@as(f64, @floatFromInt(work_elapsed)) / @as(f64, @floatFromInt(process_elapsed))) * 100;
}
