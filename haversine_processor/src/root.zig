const std = @import("std");
const Io = std.Io;

pub fn doThing(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Here, we do THING\n", .{});
}
