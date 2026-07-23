const root = @import("root");
const std = @import("std");
const testing = std.testing;

const metrics = @import("metrics.zig");

// If you're coming from C, these are the #ifndef's
const profiler_mode = if (@hasDecl(root, "profiler_mode")) root.profiler_mode else .enabled;
comptime {
    const T = @TypeOf(profiler_mode);
    if (@typeInfo(T) != .enum_literal) {
        @compileError("`profiler_mode` must be an enum literal, found `" ++ @typeName(T) ++ "`. Supported modes are `enabled, disabled, process_timer`.");
    }
    switch (profiler_mode) {
        .enabled, .disabled, .process_timer => {},
        else => {
            @compileError("Unsupported `profiler_mode` enum literal. Must be one of `enabled, disabled, process_timer`, found `" ++
                @tagName(profiler_mode) ++ "`");
        }
    }
}
const profiler_capacity: usize = if (@hasDecl(root, "profiler_capacity")) root.profiler_capacity else 255;
const cap: usize = if (profiler_mode == .enabled) profiler_capacity else 0;

const IndexInt = std.math.IntFittingRange(0, profiler_capacity);
const Bitset = std.StaticBitSet(cap);

// ANSI color escape sequences
const ansi_reset = "\x1b[0m";
const ansi_red = "\x1b[31m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";

/// The Global Instance
pub const ProfilerInstance = switch (profiler_mode) {
    .disabled => blk: {
        break :blk struct {
            // Stubs to ensure no-op and no-memory usage if profiler is not enabled
            pub fn init(_: *@This()) void {}
            pub fn print(_: *const @This(), _: *std.Io.Writer) !void {}
            pub fn startBlockTrace(_: *@This(), comptime _: []const u8, comptime _: std.builtin.SourceLocation) Trace {
                return .{};
            }
            pub fn startFnTrace(_: *@This(), comptime _: std.builtin.SourceLocation) Trace {
                return .{};
            }
        };
    },
    .process_timer => blk: {
        break :blk struct {
            start_tick: u64 = 0,
            pub fn init(self: *@This()) void {
                self.start_tick = metrics.readCpuTimer();
            }
            pub fn print(self: *const @This(), writer: *std.Io.Writer) !void {
                const process_elapsed = metrics.readCpuTimer() - self.start_tick;
                try writer.print("\n\n Total elapsed: {d} / {d:.4}ms\n\n", .{
                    process_elapsed,
                    @as(f64, @floatFromInt(process_elapsed)) / @as(f64, @floatFromInt(metrics.readCpuTimerFreq())) * 1000,
                });
            }
            pub fn startBlockTrace(_: *@This(), comptime _: []const u8, comptime _: std.builtin.SourceLocation) Trace {
                return .{};
            }
            pub fn startFnTrace(_: *@This(), comptime _: std.builtin.SourceLocation) Trace {
                return .{};
            }
        };
    },
    .enabled => blk: {
        break :blk struct {
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
                    @as(f64, @floatFromInt(process_elapsed)) / @as(f64, @floatFromInt(metrics.readCpuTimerFreq())) * 1000,
                });
            }

            fn startTrace(pf: *@This(), kind: anytype, comptime name: []const u8, comptime src: std.builtin.SourceLocation) Trace {
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
                if (profiler_mode != .enabled) return .{
                    .profiler = pf,
                    .idx = 0,
                    .kind = .dummy,
                    .parent = null,
                };

                const parent = pf.current;

                const S = struct {
                    const _tag = src;
                    var idx: IndexInt = profiler_capacity;
                };

                if (S.idx != profiler_capacity) {
                    const trace = &pf.trace_stack[S.idx];
                    if (trace.depth == 0) {
                        trace.start_tick = metrics.readCpuTimer();
                        trace.elapsed_tick_from_child = 0;
                    }
                    trace.depth += 1;
                    pf.current = S.idx;
                    return .{
                        .profiler = pf,
                        .idx = trace.id,
                        .kind = kind,
                        .parent = parent,
                    };
                }

                const id = pf.trace_count;
                if (id >= pf.trace_stack.len) {
                    std.log.err("Exceeded maximum traces. Declare and/or increase {s}profiler_capacity global{s}", .{ ansi_yellow, ansi_reset });
                    return .{
                        .profiler = pf,
                        .idx = 0,
                        .kind = .dummy,
                        .parent = null,
                    };
                }

                const self: Record = .{
                    .start_tick = metrics.readCpuTimer(),
                    .exclusive_tick = 0,
                    .elapsed_tick_from_child = 0,
                    .inclusive_tick = 0,
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

                return .{
                    .profiler = pf,
                    .idx = id,
                    .kind = kind,
                    .parent = parent,
                };
            }

            /// Starts a `block trace` (similar to a Tracy zone) allowing one to place traces
            /// anywhere in their code.
            pub fn startBlockTrace(profiler_instance: *@This(), comptime name: []const u8, comptime src: std.builtin.SourceLocation) Trace {
                return startTrace(profiler_instance, .block, name, src);
            }

            /// Exactly like a block trace except the `name` is derived from the function name.
            /// To be used at the top of a function to achieve the expected result.
            pub fn startFnTrace(profiler_instance: *@This(), comptime src: std.builtin.SourceLocation) Trace {
                return startTrace(profiler_instance, .function, src.fn_name, src);
            }
        };
    },
    else => unreachable,
};

const Trace = switch (profiler_mode) {
    .disabled, .process_timer => blk: {
        break :blk struct {
            pub fn stop(_: @This()) void {}
        };
    },
    else => blk: {
        break :blk struct {
            profiler: *ProfilerInstance,
            idx: IndexInt,
            parent: ?IndexInt,
            kind: enum { block, function, dummy },

            // Usually called with `defer t.stop()` after having started a trace.
            // This will handle accumulating or not depending on the kind of trace.
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
    },
};

const Record = struct {
    start_tick: u64,
    exclusive_tick: u64,
    elapsed_tick_from_child: u64,
    inclusive_tick: u64,
    depth: u32,
    name: []const u8,
    src: std.builtin.SourceLocation,
    id: IndexInt,
    count: u32,
};

fn percentageWorkDone(work_elapsed: u64, process_elapsed: u64) f64 {
    return (@as(f64, @floatFromInt(work_elapsed)) / @as(f64, @floatFromInt(process_elapsed))) * 100;
}

// TESTS

fn burn(n: u64) void {
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) acc +%= i *% 2654435761;
    std.mem.doNotOptimizeAway(acc);
}

test "exclusive times partition the root span exactly" {
    var pf: ProfilerInstance = .{};
    pf.init();

    const root_t = pf.startBlockTrace("root", @src());
    {
        const a = pf.startBlockTrace("a", @src());
        burn(2000);
        {
            const b = pf.startBlockTrace("b", @src());
            burn(2000);
            b.stop();
        }
        burn(2000);
        a.stop();
    }
    burn(2000);
    root_t.stop();

    try testing.expect(pf.trace_count == 3);
    try testing.expect(pf.current == null);

    const root_rec = pf.trace_stack[0];
    try testing.expect(root_rec.count == 1);

    const root_raw = root_rec.exclusive_tick + root_rec.elapsed_tick_from_child;

    var sum: u64 = 0;
    var i: IndexInt = 0;
    while (i < pf.trace_count) : (i += 1) sum += pf.trace_stack[i].exclusive_tick;

    try testing.expectEqual(root_raw, sum);
}

test "same callsite reuses one record and counts every entry" {
    var pf: ProfilerInstance = .{};
    pf.init();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const t = pf.startBlockTrace("looped", @src());
        burn(200);
        t.stop();
    }

    try testing.expect(pf.trace_count == 1);
    try testing.expect(pf.trace_stack[0].count == 100);
    try testing.expect(pf.trace_stack[0].depth == 0);
    try testing.expect(pf.current == null);
}

test "child time does not leak between entries" {
    var pf: ProfilerInstance = .{};
    pf.init();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const p = pf.startBlockTrace("p", @src());
        burn(2000);
        {
            const c = pf.startBlockTrace("c", @src());
            burn(4000);
            c.stop();
        }
        p.stop();
    }

    const p_rec = pf.trace_stack[0];
    const c_rec = pf.trace_stack[1];

    try testing.expect(p_rec.count == 5);
    try testing.expect(c_rec.count == 5);
    try testing.expect(p_rec.exclusive_tick < std.math.maxInt(u64) / 2);
    try testing.expect(p_rec.exclusive_tick > 0);
}

fn recurse(pf: *ProfilerInstance, depth: u32) void {
    const t = pf.startFnTrace(@src());
    defer t.stop();
    burn(500);
    if (depth > 0) recurse(pf, depth - 1);
}

test "recursion counts every entry but accumulates once" {
    var pf: ProfilerInstance = .{};
    pf.init();

    recurse(&pf, 4); // 5 entries

    try testing.expect(pf.trace_count == 1);
    try testing.expect(pf.trace_stack[0].count == 5);
    try testing.expect(pf.trace_stack[0].depth == 0);
    try testing.expect(pf.current == null);
    try testing.expect(pf.trace_stack[0].exclusive_tick < std.math.maxInt(u64) / 2);
}

test "fn trace nested in a block trace reports to its parent" {
    var pf: ProfilerInstance = .{};
    pf.init();

    const outer = pf.startBlockTrace("outer", @src());
    burn(1000);
    recurseOnce(&pf);
    burn(1000);
    outer.stop();

    const outer_rec = pf.trace_stack[0];
    const inner_rec = pf.trace_stack[1];

    try testing.expect(outer_rec.elapsed_tick_from_child >= inner_rec.exclusive_tick);
    try testing.expect(pf.current == null);
}

fn recurseOnce(pf: *ProfilerInstance) void {
    const t = pf.startFnTrace(@src());
    defer t.stop();
    burn(3000);
}
