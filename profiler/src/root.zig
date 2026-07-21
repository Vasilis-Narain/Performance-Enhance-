//! # Usage
//!
//! Everything sits in one global instance, so you don't have to thread a
//! profiler through your function signatures. Fixed size arrays, no
//! allocations.
//!
//! ```zig
//! const Profiler = @import("profiler");
//! const pf = &Profiler.instance;  // same instance in every file
//!
//! pf.init();  // once at the top of main, just stamps the start time
//!
//! // Block traces measure whatever scope you put them in.
//! {
//!     const main_loop = pf.startBlockTrace("main_loop", @src());
//!     defer main_loop.stop();
//! }
//!
//! // Function traces: drop one line at the top of a function and every
//! // call to it gets timed. The times add up across all the calls.
//! fn hotFn() void {
//!     const t = pf.startFnTrace(@src());
//!     defer t.stop();
//! }
//!
//! try pf.print(writer);  // dumps to whatever *std.Io.Writer you give it
//! ```
//!
//! # The \#ifndefs
//!
//! Declare either of these at file scope in your root file (the app's main):
//!
//! ```zig
//! pub const profiler_capacity: usize = 1024; // 255 by default, per array
//! pub const profiler_enabled: bool = false;  // true by default
//! ```
//!
//! Block and function traces get an array each. Anything past that gets
//! dropped (and logged), it won't crash. Setting profiler_enabled to false
//! compiles the whole thing out, arrays included.
const profiler = @import("profiler.zig");

/// Set of wrapper functions for performance counters and frequencies
pub const metrics = @import("metrics.zig");

// The Singleton
pub var instance: profiler.ProfilerInstance = .{};

test {
    _ = metrics;
    _ = profiler;
}
