const root = @import("root");
const std = @import("std");
const metrics = @import("metrics.zig");

// ANSI color escape sequences
const ansi_reset = "\x1b[0m";
const ansi_red = "\x1b[31m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";

// If you're coming from C, these are the #ifndef's
const profiler_enabled: bool = if (@hasDecl(root, "profiler_enabled")) root.profiler_enabled else true;
const profiler_capacity: usize = if (@hasDecl(root, "profiler_capacity")) root.profiler_capacity else 255;

const IndexInt = std.math.IntFittingRange(0, profiler_capacity);
const cap: usize = if (profiler_enabled) profiler_capacity else 0;

pub const ProfilerInstance = struct {
    trace_stack: [cap]Record = undefined,
    fn_trace_stack: [cap]Record = undefined,
    current: ?IndexInt = null,
    start_tick: u64 = 0,
    trace_count: IndexInt = 0,
    fn_trace_count: IndexInt = 0,

    pub fn init(self: *@This()) void {
        if (!profiler_enabled) return;
        self.start_tick = metrics.readCpuTimer();
    }

    pub fn print(self: *const @This(), writer: *std.Io.Writer) !void {
        if (!profiler_enabled) return;
        const process_elapsed = metrics.readCpuTimer() - self.start_tick;
        try writer.print(
            \\{s}
            \\  ===========================================
            \\                PROFILER STATS
            \\  ===========================================
            \\{s}
            \\ | {s}Block traces{s}:
            \\
        , .{ ansi_green, ansi_reset, ansi_yellow, ansi_reset });
        var i: IndexInt = 0;
        while (i < self.trace_count) : (i += 1) {
            try writer.print(" |  {s}::{s}[{d}:{d}]: {s}{s}{s} => elapsed: {d} ({d:.2}%)\n", .{
                self.trace_stack[i].src.file,
                self.trace_stack[i].src.fn_name,
                self.trace_stack[i].src.line,
                self.trace_stack[i].src.column,
                ansi_green,
                self.trace_stack[i].name,
                ansi_reset,
                self.trace_stack[i].elapsed_tick,
                percentageWorkDone(self.trace_stack[i].elapsed_tick, process_elapsed),
            });
        }
        try writer.print(" |\n | {s}function traces:{s}\n", .{ ansi_yellow, ansi_reset });
        i = 0;
        while (i < self.fn_trace_count) : (i += 1) {
            try writer.print(" |  {s}::{s}{s}{s}[{d}:{d}] => elapsed: {d} ({d:.2}%)\n", .{
                self.fn_trace_stack[i].src.file,
                ansi_green,
                self.fn_trace_stack[i].name,
                ansi_reset,
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

    pub fn startBlockTrace(pf: *@This(), comptime name: []const u8, comptime src: std.builtin.SourceLocation) Trace {
        if (!profiler_enabled) return .{
            .profiler = pf,
            .idx = 0,
            .kind = .dummy,
        };

        if (pf.trace_count >= pf.trace_stack.len) {
            std.log.err("Exceeded maximum traces. Edit profiler_capacity global to increase", .{});
            return .{
                .profiler = pf,
                .idx = 0,
                .kind = .dummy,
            };
        }

        const self: Record = .{
            .start_tick = metrics.readCpuTimer(),
            .end_tick = undefined,
            .elapsed_tick = 0,
            .elapsed_tick_from_child = 0,
            .name = name,
            .src = src,
            .parent = pf.current,
            .id = pf.trace_count,
        };
        pf.trace_stack[pf.trace_count] = self;
        pf.trace_count += 1;
        pf.current = self.id;

        return .{
            .profiler = pf,
            .idx = self.id,
            .kind = .block,
        };
    }

    pub fn startFnTrace(pf: *@This(), comptime src: std.builtin.SourceLocation) Trace {
        if (!profiler_enabled) return .{
            .profiler = pf,
            .idx = 0,
            .kind = .dummy,
        };
        const S = struct {
            const _tag = src;
            var idx: IndexInt = profiler_capacity;
        };

        if (S.idx != profiler_capacity) {
            const trace = &pf.fn_trace_stack[S.idx];
            trace.start_tick = metrics.readCpuTimer();
            trace.end_tick = undefined;
            return .{
                .profiler = pf,
                .idx = trace.id,
                .kind = .function,
            };
        }

        const i = pf.fn_trace_count;
        if (i >= pf.fn_trace_stack.len) {
            std.log.err("Exceeded maximum traces. Edit profiler_capacity global to increase", .{});
            return .{
                .profiler = pf,
                .idx = 0,
                .kind = .dummy,
            };
        }

        const self: Record = .{
            .start_tick = metrics.readCpuTimer(),
            .end_tick = undefined,
            .elapsed_tick = 0,
            .elapsed_tick_from_child = 0,
            .name = src.fn_name,
            .src = src,
            .parent = null,
            .id = i,
        };

        pf.fn_trace_stack[i] = self;
        pf.fn_trace_count += 1;
        S.idx = i;
        return .{
            .profiler = pf,
            .idx = S.idx,
            .kind = .function,
        };
    }
};

pub const Trace = struct {
    profiler: *ProfilerInstance,
    idx: IndexInt,
    kind: enum { block, function, dummy },

    pub fn stop(self: @This()) void {
        if (!profiler_enabled) return;
        switch (self.kind) {
            .dummy => return,
            .block => self.stopBlockTrace(),
            .function => self.updateFnTrace(),
        }
    }

    fn stopBlockTrace(self: @This()) void {
        const curr_trace = &self.profiler.trace_stack[self.idx];

        curr_trace.end_tick = metrics.readCpuTimer();
        // Note(vasilis): this feels like it should be strictly positive so I am gonna assume it is
        curr_trace.elapsed_tick = (curr_trace.end_tick - curr_trace.start_tick) - curr_trace.elapsed_tick_from_child;

        if (curr_trace.parent) |parent_id| {
            self.profiler.trace_stack[parent_id].elapsed_tick_from_child += curr_trace.elapsed_tick;
        }
        self.profiler.current = curr_trace.parent;
    }

    fn updateFnTrace(self: @This()) void {
        const curr_trace = &self.profiler.fn_trace_stack[self.idx];
        curr_trace.end_tick = metrics.readCpuTimer();
        curr_trace.elapsed_tick += curr_trace.end_tick - curr_trace.start_tick;
    }
};

const Record = struct {
    start_tick: u64,
    end_tick: u64,
    elapsed_tick: u64,
    elapsed_tick_from_child: u64,
    name: []const u8,
    src: std.builtin.SourceLocation,
    parent: ?IndexInt,
    id: IndexInt,
};

fn percentageWorkDone(work_elapsed: u64, process_elapsed: u64) f64 {
    return (@as(f64, @floatFromInt(work_elapsed)) / @as(f64, @floatFromInt(process_elapsed))) * 100;
}
