const std = @import("std");
const hs = @import("haversine.zig");
const Io = std.Io;

/// [TODO(vasilis)]: do the Thing
/// the Thing:
/// `{ "pairs" : [
///     {"x0": 3.0, "y0": 7.0, "x1": 11.879834 , "y1": 18.23424109 },
///     {...},
///     {...} //notice no end comma!
/// ]}`
pub fn generateInput(writer: *Io.Writer, uniform: bool, seed: u32, n: u32) Io.Writer.Error!void {
    // This is how we do random numbers in zig.
    // NOTE(vasilis): Try to remember how i figured this out as
    // this pattern is very common in zig stdlib.
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    const random_number = rand.intRangeAtMost(i32, -180, 180);

    try writer.print(
        \\uniform: {any}
        \\seed: {d}
        \\n: {d}
        \\random_number: {d}
        \\
    , .{ uniform, seed, n, random_number });
}
