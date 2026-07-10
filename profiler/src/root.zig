//! By convention, root.zig is the root source file when making a package.
const platform_metrics = @import("platform_metrics.zig");

pub const metrics = struct {
    pub const getOsTimerFreq = platform_metrics.getOsTimerFreq;
    pub const readCpuTimer = platform_metrics.readCpuTimer;
    pub const readOsTimer = platform_metrics.readOsTimer;
};

test {
    _ = platform_metrics;
}
