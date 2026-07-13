//! API boundary.
const Generator = @import("generator.zig");
const Parser = @import("parser.zig");

pub const generateInput = Generator.generateInput;
pub const parseJson = Parser.parseJson;
pub const Points = Parser.Points;
pub const MetricsOutput = Parser.MetricsOutput;
