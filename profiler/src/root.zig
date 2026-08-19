//! A minimal profiler without heap alloc.
//! # Usage
//!
//! ```zig
//! const Profiler = @import("profiler");
//! const pf = &Profiler.instance;  // same instance in every file
//!
//! pf.init();  // once at the top of main, just stamps the start time
//!
//! // Block traces measure whatever scope you put them in. Works as expected
//! // if used inside a loop (the timer accumulates)
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
//! # The Zig ifndefs
//!
//! Declare either of these at file scope of the root file of the executable (this will usually be `main.zig`):
//!
//! ```zig
//! pub const profiler_capacity = 32;    // 16 by default, accepts any positive integer (of course, a large number here has perf consequences)
//! pub const profiler_mode = .enabled;  // or `.disabled`: no-op and no-memory disable
//!                                      // or `.process_timer`: like `.disabled` but stamps and prints total time between
//!                                      //                    `.init()` and `.print()`. Holds one `u64` (the start tsc).
//! ```
//!
//! Adding a trace past `profiler_capacity` will result in it being
//! dropped (and logged to `stderr`), however it won't crash the program.
//!
//!
const profiler = @import("profiler.zig");

/// Set of wrapper functions for hw or os performance counters and frequencies
pub const metrics = @import("metrics.zig");

pub const rep_tester = @import("repetition_tester.zig");

/// The Global Instance
pub var instance: profiler.ProfilerInstance = .{};

test {
    _ = metrics;
    _ = profiler;
}
