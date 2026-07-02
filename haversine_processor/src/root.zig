const std = @import("std");
const assert = std.debug.assert;
const hs = @import("haversine.zig");
const Io = std.Io;

/// Generates input data for Haversine Distance Problem as `json`:
///
/// `{ "pairs" : [
///     {"x0": 3.0, "y0": 7.0, "x1": 11.879834 , "y1": 18.23424109 },
///     {...},
///     {...} //notice no end comma!
/// ]}`
pub fn generateInput(sum_writer: *Io.Writer, writer: *Io.Writer, uniform: bool, seed: u32, n: u32, statistic: *f64) Io.Writer.Error!void {
    assert(n > 0);

    try writer.print("{{ \"pairs\" : [\n", .{});

    // This is how we do random numbers in zig.
    // NOTE(vasilis): Try to remember how i figured this out as
    // this pattern is very common in zig stdlib.
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    const pairs_per_cluster: u32 = blk: {
        if (!uniform) {
            const cluster_count: f64 = @floatFromInt(@intFromEnum(rand.enumValue(ClusterCount)));
            const n_float: f64 = @floatFromInt(n);
            break :blk @intFromFloat(n_float / cluster_count);
        } else {
            break :blk undefined;
        }
    };

    var i: u32 = 0;
    var min_x: f64 = undefined;
    var max_x: f64 = undefined;
    var min_y: f64 = undefined;
    var max_y: f64 = undefined;
    if (uniform) {
        min_x = -180;
        max_x = 180;
        min_y = -90;
        max_y = 90;
    }
    while (i < n) : (i += 1) {
        if (!uniform and (i % pairs_per_cluster == 0)) {
            const size = rand.intRangeAtMost(u8, 8, 80);
            generateCluster(rand, size, &min_x, &max_x, &min_y, &max_y);
        }
        const x0 = floatRangeAtMost(rand, f64, min_x, max_x);
        const y0 = floatRangeAtMost(rand, f64, min_y, max_y);
        const x1 = floatRangeAtMost(rand, f64, min_x, max_x);
        const y1 = floatRangeAtMost(rand, f64, min_y, max_y);
        const haversine_distance = hs.referenceHaversine(x0, y0, x1, y1, hs.EARTH_RADIUS);
        const haversine_bits: u64 = @bitCast(haversine_distance);
        try sum_writer.writeInt(u64, haversine_bits, .native);
        statistic.* += haversine_distance;

        if (i > 0) try writer.print(",\n", .{});
        try writer.print(
            "{{\"x0\": {d:.16}, \"y0\": {d:.16}, \"x1\": {d:.16}, \"y1\": {d:.16} }}",
            .{ x0, y0, x1, y1 },
        );
    }
    statistic.* /= @as(f64, @floatFromInt(n));
    const stat_bits: u64 = @bitCast(statistic.*);
    try sum_writer.writeInt(u64, stat_bits, .native);
    try writer.print("\n]}}", .{});
}

const ClusterCount = enum(u8) {
    _16 = 16,
    _32 = 32,
    _64 = 64,
};

/// Returns random float in the range [min, max)
/// min and max must match the desired return type
fn floatRangeAtMost(rand: std.Random, comptime T: type, min: T, max: T) T {
    assert(max > min);
    return min + (max - min) * rand.float(T);
}

/// Generates a random cluster of specified size.
///
/// Stores result in min/max x/y
fn generateCluster(rand: std.Random, size: u8, min_x: *f64, max_x: *f64, min_y: *f64, max_y: *f64) void {
    min_y.* = floatRangeAtMost(rand, f64, -90, 90 - size);
    max_y.* = min_y.* + size;

    min_x.* = floatRangeAtMost(rand, f64, -180, 180 - size);
    max_x.* = min_x.* + size;
}
