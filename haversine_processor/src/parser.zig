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
pub fn parseJson(json_reader: *Io.Reader, byte_reader: *Io.Reader, opts: anytype) !void {
    _ = byte_reader;
    _ = opts;

    while (json_reader.takeDelimiter('\n')) |raw| {
        var line = raw orelse break;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line.len -= 1;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}
