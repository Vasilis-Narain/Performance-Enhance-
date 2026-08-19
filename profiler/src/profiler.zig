const std = @import("std");
const root = @import("root");
const testing = std.testing;

const metrics = @import("metrics.zig");

// If you're coming from C, these are the #ifndef's
const profiler_capacity = if (@hasDecl(root, "profiler_capacity")) root.profiler_capacity else 16;
comptime {
    if (profiler_capacity < 0) {
        @compileError(std.fmt.comptimePrint("`profiler_capacity` must be positive, found `{d}`", .{profiler_capacity}));
    }
}

const Mode = enum { enabled, disabled, process_timer };
const profiler_mode: Mode = if (@hasDecl(root, "profiler_mode")) root.profiler_mode else .enabled;
const cap = if (profiler_mode == .enabled and profiler_capacity > 0) profiler_capacity else 0;

const IndexInt = std.math.IntFittingRange(0, profiler_capacity);
const Bitset = std.StaticBitSet(cap);

// ANSI color escape sequences
const ansi_reset = "\x1b[0m";
const ansi_red = "\x1b[31m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";

/// The Global Instance
pub const ProfilerInstance = struct {
    internal_profiler: ProfilerType = .{},

    /// No dynamic dispatch here folks :)
    const ProfilerType = switch (profiler_mode) {
        .enabled => EnabledProfilerInstance,
        .process_timer => ProcessTimerProfilerInstance,
        .disabled => DisabledProfilerInstance,
    };

    /// Stamps the start tick for the entire process
    pub fn init(self: *@This()) void {
        self.internal_profiler.init();
    }

    /// Prints results to the supplied `std.Io.Writer` interface.
    pub fn print(self: *const @This(), writer: *std.Io.Writer) !void {
        return self.internal_profiler.print(writer);
    }

    /// Starts a 'bandwidth trace' that measures throughput as well as time.
    pub fn startBandwithTrace(self: *@This(), comptime name: []const u8, byte_count: u64, comptime src: std.builtin.SourceLocation) Trace {
        return self.internal_profiler.startBandwidthTrace(name, byte_count, src);
    }

    /// Starts a `block trace` (similar to a Tracy zone) allowing one to place traces
    /// anywhere in their code.
    pub fn startBlockTrace(self: *@This(), comptime name: []const u8, comptime src: std.builtin.SourceLocation) Trace {
        return self.internal_profiler.startBlockTrace(name, src);
    }

    /// Exactly like a block trace except the `name` is derived from the function name.
    /// To be used at the top of a function to achieve the expected result.
    pub fn startFnTrace(self: *@This(), comptime src: std.builtin.SourceLocation) Trace {
        return self.internal_profiler.startFnTrace(src);
    }
};

/// Stubs to ensure no-op and no-memory usage if profiler is disabled
const DisabledProfilerInstance = struct {
    pub fn init(_: *@This()) void {}
    pub fn print(_: *const @This(), _: *std.Io.Writer) !void {}
    pub fn startBlockTrace(_: *@This(), comptime _: []const u8, comptime _: std.builtin.SourceLocation) Trace {
        return .{};
    }
    pub fn startFnTrace(_: *@This(), comptime _: std.builtin.SourceLocation) Trace {
        return .{};
    }
};

/// Mostly like Disabled but will stamp (and print if .print() is called) total process time
const ProcessTimerProfilerInstance = struct {
    start_tick: u64 = 0,
    pub fn init(self: *@This()) void {
        self.start_tick = metrics.readCpuTimer();
    }
    pub fn print(self: *const @This(), writer: *std.Io.Writer) !void {
        const process_elapsed = metrics.readCpuTimer() - self.start_tick;
        const cpu_freq = metrics.readCpuTimerFreq();
        try writer.print("\n\n Total elapsed: {d} / {d:.4}ms\n\n", .{
            process_elapsed,
            @as(f64, @floatFromInt(process_elapsed)) / @as(f64, @floatFromInt(cpu_freq)) * 1000,
        });
    }
    pub fn startBlockTrace(_: *@This(), comptime _: []const u8, comptime _: std.builtin.SourceLocation) Trace {
        return .{};
    }
    pub fn startFnTrace(_: *@This(), comptime _: std.builtin.SourceLocation) Trace {
        return .{};
    }
};

/// The actual instance
const EnabledProfilerInstance = struct {
    trace_stack: [cap]Record = undefined,
    trace_bitset: Bitset = .initEmpty(),
    fn_trace_bitset: Bitset = .initEmpty(),
    current: ?IndexInt = null,
    start_tick: u64 = 0,
    trace_count: IndexInt = 0,

    /// Stamps the start tick for the entire process
    pub fn init(self: *@This()) void {
        self.start_tick = metrics.readCpuTimer();
    }

    /// Prints results to the supplied `std.Io.Writer` interface.
    pub fn print(self: *const @This(), writer: *std.Io.Writer) !void {
        const cpu_freq = metrics.readCpuTimerFreq();
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
        var block_iterator = self.trace_bitset.iterator(.{});
        while (block_iterator.next()) |i| {
            try writer.print(" |  {s}::{s}[{d}:{d}]({d}): {s}{s}{s} => elapsed: {d} ({d:.2}%", .{
                self.trace_stack[i].src.file,
                self.trace_stack[i].src.fn_name,
                self.trace_stack[i].src.line,
                self.trace_stack[i].src.column,
                self.trace_stack[i].count,
                ansi_green,
                self.trace_stack[i].name,
                ansi_reset,
                self.trace_stack[i].exclusive_tick,
                percentageWorkDone(self.trace_stack[i].exclusive_tick, process_elapsed),
            });
            if (self.trace_stack[i].exclusive_tick != self.trace_stack[i].inclusive_tick) {
                try writer.print(", {d:.2}% w/children", .{
                    percentageWorkDone(self.trace_stack[i].inclusive_tick, process_elapsed),
                });
            }
            if (self.trace_stack[i].processed_byte_count > 0) {
                const megabyte: f64 = 1024 * 1024;
                const gigabyte: f64 = 1024 * megabyte;
                const seconds: f64 = @as(f64, @floatFromInt(self.trace_stack[i].inclusive_tick)) / @as(f64, @floatFromInt(cpu_freq));
                const bytes_per_second: f64 = @as(f64, @floatFromInt(self.trace_stack[i].processed_byte_count)) / seconds;
                const megabytes = @as(f64, @floatFromInt(self.trace_stack[i].processed_byte_count)) / megabyte;
                const gigabytes_per_second = bytes_per_second / gigabyte;
                try writer.print(", {d:.3}mb at {d:.2}GiB/s", .{ megabytes, gigabytes_per_second });
            }
            try writer.writeAll(")\n");
        }
        try writer.print(" |\n | {s}Function traces:{s}\n", .{ ansi_yellow, ansi_reset });
        var fn_iterator = self.fn_trace_bitset.iterator(.{});
        while (fn_iterator.next()) |i| {
            try writer.print(" |  {s}::{s}{s}{s}[{d}:{d}]({d}) => elapsed: {d} ({d:.2}%", .{
                self.trace_stack[i].src.file,
                ansi_green,
                self.trace_stack[i].name,
                ansi_reset,
                self.trace_stack[i].src.line,
                self.trace_stack[i].src.column,
                self.trace_stack[i].count,
                self.trace_stack[i].exclusive_tick,
                percentageWorkDone(self.trace_stack[i].exclusive_tick, process_elapsed),
            });
            if (self.trace_stack[i].exclusive_tick != self.trace_stack[i].inclusive_tick) {
                try writer.print(", {d:.2}% w/children", .{
                    percentageWorkDone(self.trace_stack[i].inclusive_tick, process_elapsed),
                });
            }
            try writer.writeAll(")\n");
        }
        try writer.print(" |\n | Total elapsed: {d} / {d:.4}ms\n\n", .{
            process_elapsed,
            @as(f64, @floatFromInt(process_elapsed)) / @as(f64, @floatFromInt(cpu_freq)) * 1000,
        });
    }

    fn startTrace(pf: *@This(), kind: anytype, comptime name: []const u8, byte_count: u64, comptime src: std.builtin.SourceLocation) Trace {
        const T = @TypeOf(kind);
        comptime {
            if (@typeInfo(T) != .enum_literal) {
                @compileError("Expected an enum literal, found `" ++ @typeName(T) ++ "`");
            }
            switch (kind) {
                .function, .block => {},
                else => @compileError("Expected enum literals `function, block`, found `" ++ @tagName(kind) ++ "`"),
            }
        }

        const parent = pf.current;

        const S = struct {
            const _tag = src;
            var idx: IndexInt = profiler_capacity;
        };

        if (S.idx != profiler_capacity) {
            const record = &pf.trace_stack[S.idx];
            if (record.depth == 0) {
                record.start_tick = metrics.readCpuTimer();
                record.elapsed_tick_from_child = 0;
            }
            record.processed_byte_count += byte_count;
            record.depth += 1;
            pf.current = S.idx;
            return .{ .inner_trace_handle = .{
                .profiler = pf,
                .idx = record.id,
                .kind = kind,
                .parent = parent,
            } };
        }

        const id = pf.trace_count;
        if (id >= pf.trace_stack.len) {
            std.log.err("Exceeded maximum traces. Declare and/or increase {s}profiler_capacity global{s}", .{
                ansi_yellow,
                ansi_reset,
            });
            return .{ .inner_trace_handle = .{
                .profiler = pf,
                .idx = 0,
                .kind = .dummy,
                .parent = null,
            } };
        }

        const self: Record = .{
            .start_tick = metrics.readCpuTimer(),
            .exclusive_tick = 0,
            .elapsed_tick_from_child = 0,
            .inclusive_tick = 0,
            .processed_byte_count = byte_count,
            .name = name,
            .src = src,
            .depth = 1,
            .id = id,
            .count = 0,
        };
        pf.trace_stack[id] = self;
        pf.trace_count +|= 1;
        pf.current = id;
        S.idx = id;
        switch (kind) {
            .block => pf.trace_bitset.set(S.idx),
            .function => pf.fn_trace_bitset.set(S.idx),
            else => unreachable,
        }

        return .{ .inner_trace_handle = .{
            .profiler = pf,
            .idx = id,
            .kind = kind,
            .parent = parent,
        } };
    }

    /// Starts a 'bandwidth trace' that measures throughput as well as time.
    pub fn startBandwidthTrace(profiler_instance: *@This(), comptime name: []const u8, byte_count: u64, comptime src: std.builtin.SourceLocation) Trace {
        return startTrace(profiler_instance, .block, name, byte_count, src);
    }

    /// Starts a `block trace` (similar to a Tracy zone) allowing one to place traces
    /// anywhere in their code.
    pub fn startBlockTrace(profiler_instance: *@This(), comptime name: []const u8, comptime src: std.builtin.SourceLocation) Trace {
        return startTrace(profiler_instance, .block, name, 0, src);
    }

    /// Exactly like a block trace except the `name` is derived from the function name.
    /// To be used at the top of a function to achieve the expected result.
    pub fn startFnTrace(profiler_instance: *@This(), comptime src: std.builtin.SourceLocation) Trace {
        return startTrace(profiler_instance, .function, src.fn_name, 0, src);
    }
};

const Trace = struct {
    const TraceHandleType = switch (profiler_mode) {
        .disabled, .process_timer => DisabledTrace,
        .enabled => EnabledTrace,
    };
    inner_trace_handle: TraceHandleType,

    /// Typically called with `defer t.stop()` after having started a trace.
    /// This will handle accumulating or not depending on the kind of trace.
    pub fn stop(self: @This()) void {
        self.inner_trace_handle.stop();
    }
};

const DisabledTrace = struct {
    pub fn stop(_: @This()) void {}
};

const EnabledTrace = struct {
    profiler: *ProfilerInstance.ProfilerType,
    idx: IndexInt,
    parent: ?IndexInt,
    kind: enum { block, function, dummy },

    /// Typically called with `defer t.stop()` after having started a trace.
    pub fn stop(self: @This()) void {
        const curr_trace = &self.profiler.trace_stack[self.idx];

        self.profiler.current = self.parent;

        curr_trace.depth -= 1;
        curr_trace.count +|= 1;
        if (curr_trace.depth != 0) return;

        const curr_time_block = metrics.readCpuTimer() - curr_trace.start_tick;

        curr_trace.inclusive_tick += curr_time_block;
        curr_trace.exclusive_tick += curr_time_block - curr_trace.elapsed_tick_from_child;

        if (self.parent) |parent_id| {
            self.profiler.trace_stack[parent_id].elapsed_tick_from_child += curr_time_block;
        }
    }
};

const Record = struct {
    start_tick: u64,
    exclusive_tick: u64,
    elapsed_tick_from_child: u64,
    inclusive_tick: u64,
    processed_byte_count: u64,
    depth: u32,
    count: u32, // hopefully you aren't profiling something called over 4b times. Anyway, it wraps
    id: IndexInt,
    name: []const u8,
    src: std.builtin.SourceLocation,
};

fn percentageWorkDone(work_elapsed: u64, process_elapsed: u64) f64 {
    return (@as(f64, @floatFromInt(work_elapsed)) / @as(f64, @floatFromInt(process_elapsed))) * 100;
}
