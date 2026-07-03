const std = @import("std");
const assert = std.debug.assert;
const hs = @import("haversine.zig");
const Io = std.Io;

/// Parses input json for Haversine Distance Problem:
///
/// `{ "pairs" : [
///     {"x0": 3.0, "y0": 7.0, "x1": 11.879834 , "y1": 18.23424109 },
///     {...},
///     {...}
/// ]}`
pub fn parseJson() void {}
