const std = @import("std");
const hs = @import("haversine.zig");
const Io = std.Io;

// TODO(vasilis): do the thing
// the Thing: { "pairs" : [
//              {"x0": 3.0, "y0": 7.0, "x1": ... , "y1": ... },
//              {...},
//              {...} //notice no end comma!
//          ]}
//
// CLI level API:
//  executable -generate [uniform/cluster] [random seed] [number of coordinate pairs to generate]
pub fn generateInput(writer: *Io.Writer, uniform: bool, seed: u32, n: u32) Io.Writer.Error!void {
    try writer.print("Here, we do THING\n", .{});

    _ = uniform;
    _ = seed;
    _ = n;
}
