const std = @import("std");
const assert = std.debug.assert;
const hs = @import("haversine.zig");
const Io = std.Io;

/// Generates input data for Haversine Distance Problem as `json`:
///
/// `{ "pairs" : [
///     {"x0": 3.0, "y0": 7.0, "x1": 11.879834 , "y1": 18.23424109 },
///     {...},
///     {...}
/// ]}`
///
/// Also generates a `.f64` containing the individual haversine distance
/// calculations in byte format, with the last 8 bytes being the statistic (average).
///
/// inputs:
///    `byteWriter`: Writer instance to write the .f64 file.
///    `writer`: Writer instance to write the .json file.
///    `opts`: Pointer to a var struct that has at least these fields: &.{
///        `uniform`: bool - `true` for uniform sampling, `false` for cluster sampling
///        `seed`: u32 - random seed
///        `n`: u32 - pairs to generate
///        `statistic`: f64 - number holding statistic (for now average) of sums.
///    }
pub fn generateInput(byteWriter: *Io.Writer, writer: *Io.Writer, opts: anytype) Io.Writer.Error!void {
    assert(opts.n > 0);

    try writer.print("{{ \"pairs\" : [\n", .{});

    // This is how we do random numbers in zig.
    // NOTE(vasilis): Try to remember how i figured this out as
    // this pattern is very common in zig stdlib.
    var prng: std.Random.DefaultPrng = .init(opts.seed);
    const rand = prng.random();

    const pairs_per_cluster: u32 = blk: {
        if (!opts.uniform) {
            const cluster_count: f64 = @floatFromInt(@intFromEnum(rand.enumValue(ClusterCount)));
            const n_float: f64 = @floatFromInt(opts.n);
            break :blk @intFromFloat(n_float / cluster_count);
        } else {
            break :blk undefined; // undefined here so program crashes if we accidentally use it
        }
    };

    var cluster: Cluster = .{};
    var i: u32 = 0;
    while (i < opts.n) : (i += 1) {
        if (!opts.uniform and (i % pairs_per_cluster == 0)) {
            const size = rand.intRangeAtMost(u8, 8, 80);
            cluster.randomiseCluster(rand, size);
        }
        const x0 = floatRangeAtMost(rand, f64, cluster.min_x, cluster.max_x);
        const y0 = floatRangeAtMost(rand, f64, cluster.min_y, cluster.max_y);
        const x1 = floatRangeAtMost(rand, f64, cluster.min_x, cluster.max_x);
        const y1 = floatRangeAtMost(rand, f64, cluster.min_y, cluster.max_y);
        const haversine_distance = hs.referenceHaversine(x0, y0, x1, y1, hs.EARTH_RADIUS);
        const haversine_bits: u64 = @bitCast(haversine_distance);
        try byteWriter.writeInt(u64, haversine_bits, .native);
        opts.statistic += haversine_distance;

        if (i > 0) try writer.print(",\n", .{});
        try writer.print(
            "{{\"x0\": {d:.16}, \"y0\": {d:.16}, \"x1\": {d:.16}, \"y1\": {d:.16} }}",
            .{ x0, y0, x1, y1 },
        );
    }
    opts.statistic /= @as(f64, @floatFromInt(opts.n));
    const stat_bits: u64 = @bitCast(opts.statistic);
    try byteWriter.writeInt(u64, stat_bits, .native);
    try writer.print("\n]}}", .{});
}

/// Enum to randomise discrete Cluster Counts.
///
/// Not meant to be used explitictly.
const ClusterCount = enum(u8) {
    _16 = 16,
    _32 = 32,
    _64 = 64,
};

/// Defaults to full sphere cluster.
const Cluster = struct {
    min_x: f64 = -180,
    max_x: f64 = 180,
    min_y: f64 = -90,
    max_y: f64 = 90,

    /// Generates a random cluster of specified size.
    ///
    /// Requires std.Random interface initialised with a PRNG
    ///
    /// Stores result in min/max x/y.
    fn randomiseCluster(self: *@This(), rand: std.Random, size: u8) void {
        self.min_y = floatRangeAtMost(rand, f64, -90, 90 - size);
        self.max_y = self.min_y + size;

        self.min_x = floatRangeAtMost(rand, f64, -180, 180 - size);
        self.max_x = self.min_x + size;
    }
};

/// Returns random float in the range [min, max)
/// min and max must match the desired return type
fn floatRangeAtMost(rand: std.Random, comptime T: type, min: T, max: T) T {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("floatRangeAtMost only accepts float types, found " ++ @typeName(T)),
        }
    }
    assert(max > min);
    return min + (max - min) * rand.float(T);
}
