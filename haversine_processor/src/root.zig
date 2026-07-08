//! API boundary.
const Generator = @import("generator.zig");
const Parser = @import("parser.zig");

pub const generateInput = Generator.generateInput;
pub const parseJson = Parser.parseJson;
