const std = @import("std");
const metrics = @import("metrics.zig");

// ANSI color escape sequences
const ANSI_RESET = "\x1b[0m";
const ANSI_RED = "\x1b[31m";
const ANSI_GREEN = "\x1b[32m";
const ANSI_YELLOW = "\x1b[33m";

pub const Profiler = struct {
    trace_stack: [32]*trace,
    trace_stack_count: u8,
    trace_count: u8,
    allocator: std.mem.Allocator,
    start_tick: u64,

    pub fn init(self: *@This(), allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .trace_stack = undefined,
            .trace_stack_count = 0,
            .trace_count = 0,
            .start_tick = metrics.readCpuTimer(),
        };
    }

    pub fn deinit(self: *@This(), writer: *std.Io.Writer) !void {
        const process_elapsed = metrics.readCpuTimer() - self.start_tick;
        try writer.print(
            \\
            \\  ===========================================
            \\                PROFILER STATS
            \\  ===========================================
            \\
            \\
        , .{});
        var i: u8 = 0;
        while (i < self.trace_count) : (i += 1) {
            try writer.print(" |  {s}[{d}:{d}]: {s}{s}{s} => elapsed: {d} ({d:.2}%)\n", .{
                self.trace_stack[i].src.fn_name,
                self.trace_stack[i].src.line,
                self.trace_stack[i].src.column,
                ANSI_GREEN,
                self.trace_stack[i].name,
                ANSI_RESET,
                self.trace_stack[i].elapsed_tick,
                percentageWorkDone(self.trace_stack[i].elapsed_tick, process_elapsed),
            });
            self.allocator.free(self.trace_stack[i].name);
        }
        try writer.print(" |\n |  Total elapsed: {d} / {d:.4}ms\n\n", .{
            process_elapsed,
            @as(f64, @floatFromInt(process_elapsed)) / @as(f64, @floatFromInt(metrics.readCpuTimerFreq())),
        });
    }
};

pub const trace = struct {
    start_tick: u64,
    end_tick: u64,
    elapsed_tick: u64,
    elapsed_tick_from_child: u64,
    name: []const u8,
    src: std.builtin.SourceLocation,
    profiler: *Profiler,
    idx: u8,

    pub fn init(pf: *Profiler, name: []const u8, comptime src: std.builtin.SourceLocation) !*@This() {
        const self = try pf.allocator.create(@This());
        errdefer pf.allocator.destroy(self);

        self.* = .{
            .idx = pf.trace_stack_count + 1,
            .start_tick = metrics.readCpuTimer(),
            .end_tick = undefined,
            .elapsed_tick = 0,
            .elapsed_tick_from_child = 0,
            .name = try pf.allocator.dupe(u8, name),
            .src = src,
            .profiler = pf,
        };
        pf.trace_stack[pf.trace_count] = self;
        pf.trace_count += 1;
        pf.trace_stack_count += 1;

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.end_tick = metrics.readCpuTimer();
        // Note(vasilis): this feels like it should be strictly positive so I am gonna assume it is
        self.elapsed_tick = (self.end_tick - self.start_tick) - self.elapsed_tick_from_child;
        self.profiler.trace_stack_count -= 1;

        if (self.idx > 0) {
            self.profiler.trace_stack[self.idx - 1].elapsed_tick_from_child += self.elapsed_tick;
        }
    }
};

fn percentageWorkDone(work_elapsed: u64, process_elapsed: u64) f64 {
    return (@as(f64, @floatFromInt(work_elapsed)) / @as(f64, @floatFromInt(process_elapsed))) * 100;
}
