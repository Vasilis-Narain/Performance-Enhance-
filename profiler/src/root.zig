//! Usage:
//! ```
//!    const Profiler = @import("profiler");
//!    const Trace = Profiler.Trace;
//!
//!    // Somewhere at the top of the program's entry point (main)
//!    const pf = Profiler.profiler_stack_ptr;
//!    pf.init(std.mem.Allocator); // make sure the Allocator passed in's intended life time matches the one intended for the profiler
//!                                // this same allocator will also be used by all the traces.
//!
//!    // .deinit() only required if initialized with an Allocator that is not an Arena
//!    // and if the profiler isn't meant to run for the program's lifetime.
//!    defer pf.deinit();
//!
//!
//!    // For traces
//!    {
//!        // Initialise trace and stop with defer when out of scope.
//!        const main_loop_trace: *Trace = try .init(pf, "main_loop", @src());
//!        defer main_loop_trace.stop();
//!
//!        //inner loop
//!        const inner_loop_trace: *Trace = try .init(pf, "inner_loop", @src());
//!        while (true) {
//!            // Doing the thing
//!        }
//!        inner_loop_trace.stop(); // could've also used a block with defer like with main_loop_trace
//!                                   // but sometimes the thing we want to measure can't be blocked off
//!                                   // from the rest of the program. In those cases just do this.
//!    }
//!
//!    try pf.print(*std.Io.Writer); //prints all traces to the chosen Writer
//! ```
//!
//! Initializing the Profiler.profiler_instance once in main allows for traces to be initialized in, and ran from,
//! multiple files as long as this library is imported to that file. Without needing to change function signatures.
//!
const profiler = @import("profiler.zig");
pub const Trace = profiler.Trace;

/// Set of wrapper functions for performance counters and frequencies
pub const metrics = @import("metrics.zig");

//Note(vasilis): Not sure if this is the proper way to do this.. I want the user
//to be able to call .init once in main, and then by simply importing
//this file (or the library) to wherever is needed then they can
//have access to the same global Profiler instance
var internal_profiler_instance: profiler.ProfilerInstance = undefined;
pub const profiler_instance_ptr = &internal_profiler_instance;

test {
    _ = metrics;
    _ = profiler;
}
