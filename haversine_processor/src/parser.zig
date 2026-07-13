const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const hs = @import("haversine.zig");

const Profiler = @import("profiler");
const metrics = Profiler.metrics;

pub const MetricsOutput = struct {
    misc_setup_elapsed: u64 = 0,
    parse_sum_elapsed: u64 = 0,
};

/// Parses input json for Haversine Distance Problem:
///
/// MUST be this format.
///
/// Use -generate to achieve this :D
///
/// `{ "pairs" : [
///     {"x0": 3.0, "y0": 7.0, "x1": 11.879834 , "y1": 18.23424109 },
///     {...},
///     {...}
/// ]}`
pub fn parseJson(allocator: std.mem.Allocator, json_reader: *Io.Reader, metrics_output: *MetricsOutput) !Points {
    const misc_setup_start = metrics.readCpuTimer();
    var flags: Flags = .{};

    var int_part_buffer: [3]u8 = undefined;
    var decimal_part_buffer: [16]u8 = undefined;

    // 0 = x0, 1 = y0, 2 = x1, 3 = y1
    var point_index: u8 = 0;

    // 1024 seems like a sensible starting array size for this problem
    var output_points: Points = try .init(allocator, 1024);

    const misc_setup_end = metrics.readCpuTimer();
    metrics_output.misc_setup_elapsed = misc_setup_end - misc_setup_start;

    const parse_sum_start = metrics.readCpuTimer();
    // Skip first line
    while (json_reader.takeByte()) |char| {
        if (char == '\n' or char == '\r') {
            flags.last_iter_was_new_line = true;
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => return error.NoPointLines,
        else => return err,
    }

    while (json_reader.takeByte()) |char| {

        // Skip newline chars
        if (char == '\n' or char == '\r') {
            if (!flags.last_iter_was_new_line) {
                flags.last_iter_was_new_line = true;

                if (!flags.committed) {
                    const curr_point: Point = @enumFromInt(3);
                    const curr_num = buildFloat(int_part_buffer[0..flags.int_part_index], decimal_part_buffer[0..flags.decimal_part_index], flags.curr_num_negative);
                    output_points.insertPoint(curr_point, curr_num, output_points.count);
                } else {
                    flags.committed = false;
                }

                flags.flushNumberFlags();
                point_index = 0;

                const i = output_points.count;
                output_points.sums[i] = hs.referenceHaversine(
                    output_points.x0[i],
                    output_points.y0[i],
                    output_points.x1[i],
                    output_points.y1[i],
                    hs.EARTH_RADIUS,
                );
                output_points.total += output_points.sums[i];
                output_points.count += 1;
                continue;
            } else {
                flags.last_iter_was_new_line = false;
                continue;
            }
        }
        flags.last_iter_was_new_line = false;
        if (char == ' ') continue;
        if (char == '-') {
            flags.curr_num_negative = true;
            continue;
        }

        // ArrayList like resizing heuristic
        if (output_points.count >= output_points.curr_buffer_size) {
            try output_points.realloc(output_points.curr_buffer_size * 2);
        }

        if (!flags.parsing_string and (char >= '0' and char <= '9')) {
            if (flags.parsing_int_part) {
                int_part_buffer[flags.int_part_index] = char;
                flags.int_part_index += 1;
            }
            if (flags.parsing_decimal_part) {
                decimal_part_buffer[flags.decimal_part_index] = char;
                flags.decimal_part_index += 1;
            }
        }

        const char_enum: SpecialChar = @enumFromInt(char);
        switch (char_enum) {
            .semicolon => {
                flags.parsing_int_part = true;
                flags.committed = false;
                continue;
            },
            .comma => {
                const curr_point: Point = @enumFromInt(point_index);
                point_index += 1;

                const curr_num = buildFloat(int_part_buffer[0..flags.int_part_index], decimal_part_buffer[0..flags.decimal_part_index], flags.curr_num_negative);
                output_points.insertPoint(curr_point, curr_num, output_points.count);
                flags.committed = true;
                flags.flushNumberFlags();

                continue;
            },
            .close_square => break,
            .period => {
                flags.parsing_int_part = false;
                flags.parsing_decimal_part = true;
                continue;
            },
            .quotes => flags.parsing_string = !flags.parsing_string,
            else => continue,
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const parse_sum_end = metrics.readCpuTimer();
    metrics_output.parse_sum_elapsed = parse_sum_end - parse_sum_start;

    return output_points;
}

const Flags = struct {
    last_iter_was_new_line: bool = false,
    parsing_int_part: bool = false,
    parsing_decimal_part: bool = false,
    curr_num_negative: bool = false,
    parsing_string: bool = false,
    committed: bool = false,
    int_part_index: usize = 0,
    decimal_part_index: usize = 0,

    pub fn flushNumberFlags(self: *@This()) void {
        self.parsing_int_part = false;
        self.parsing_decimal_part = false;
        self.curr_num_negative = false;
        self.int_part_index = 0;
        self.decimal_part_index = 0;
    }
};

/// Clinger Fast Path algorithm
fn buildFloat(int_digits: []u8, fractional_digits: []u8, is_negative: bool) f64 {
    var significand: u64 = 0;
    for (int_digits) |ascii_digit| {
        significand = significand * 10 + (ascii_digit - '0');
    }
    for (fractional_digits) |ascii_digit| {
        significand = significand * 10 + (ascii_digit - '0');
    }
    const fractional_count = fractional_digits.len;

    const powers_of_ten = [_]f80{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16 };

    const magnitude = @as(f80, @floatFromInt(significand)) / powers_of_ten[fractional_count];

    const result = if (is_negative) -magnitude else magnitude;

    return @floatCast(result);
}

pub const Point = enum(u8) {
    x0,
    y0,
    x1,
    y1,
};

/// Heap allocated SOA to hold output
/// Note(vasilis): this is not needed for current hw but might be in the future
pub const Points = struct {
    x0: []f64,
    y0: []f64,
    x1: []f64,
    y1: []f64,
    sums: []f64,
    total: f64,
    curr_buffer_size: u64,
    count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: u32) !@This() {
        const x0 = try allocator.alloc(f64, size);
        errdefer allocator.free(x0);
        const y0 = try allocator.alloc(f64, size);
        errdefer allocator.free(y0);
        const x1 = try allocator.alloc(f64, size);
        errdefer allocator.free(x1);
        const y1 = try allocator.alloc(f64, size);
        errdefer allocator.free(y1);
        const sums = try allocator.alloc(f64, size);
        errdefer allocator.free(sums);
        return .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .sums = sums,
            .total = 0,
            .allocator = allocator,
            .curr_buffer_size = @intCast(size),
            .count = 0,
        };
    }

    pub fn insertPoint(self: *@This(), point: Point, value: f64, index: usize) void {
        switch (point) {
            .x0 => self.x0[index] = value,
            .y0 => self.y0[index] = value,
            .x1 => self.x1[index] = value,
            .y1 => self.y1[index] = value,
        }
    }

    pub fn realloc(self: *@This(), new_size: u64) !void {
        self.x0 = try self.allocator.realloc(self.x0, new_size);
        self.y0 = try self.allocator.realloc(self.y0, new_size);
        self.x1 = try self.allocator.realloc(self.x1, new_size);
        self.y1 = try self.allocator.realloc(self.y1, new_size);
        self.sums = try self.allocator.realloc(self.sums, new_size);
        self.curr_buffer_size = new_size;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.x0);
        self.allocator.free(self.y0);
        self.allocator.free(self.x1);
        self.allocator.free(self.y1);
        self.allocator.free(self.sums);
    }
};

const SpecialChar = enum(u8) {
    semicolon = ':',
    comma = ',',
    close_square = ']',
    period = '.',
    quotes = '"',
    _,
};
