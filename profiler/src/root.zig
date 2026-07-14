//! Usage:
//! `
//!    const Profiler = @import("profiler");
//!    const metrics = Profiler.metrics;
//!    const profiler = Profiler.profiler;
//!
//!    // Somewhere at the top of the program's entry point (main)
//!    const pf = &Profiler.profiler_instance;
//!    pf.init(std.mem.Allocator); // make sure the Allocator passed in's intended life time matches the one intended for the profiler
//!                                // this same allocator will also be used by all the traces.
//!
//!    var main_loop_trace: *profiler.trace = undefined; // initialize as undefined at the top
//!
//!    // For traces
//!    {
//!        main_loop_trace = try .init(pf, "main_loop", @src());
//!        defer main_loop_trace.deinit();
//!
//!        //inner loop
//!        const inner_loop_trace: *profiler.trace = .init(pf, "inner_loop", @src()); // handy one liner
//!        while (true) {
//!            // Doing the thing
//!        }
//!        inner_loop_trace.deinit(); // could've also used a block with defer like with main_loop_trace
//!                                   // but sometimes the thing we want to measure can't be blocked off
//!                                   // from the rest of the program. In those cases just do this.
//!    }
//!
//!    try pf.deinit(*std.Io.Writer); //at the end of the process, prints all traces with chosen Writer
//! `
//!
//! Initializing the Profiler.profiler_instance once in main allows for traces to be initialized and ran from
//! multiple files as long as this library is imported to that file without
//! needing to change function signatures. Doubt this is particularly thread safe..
//!
pub const metrics = @import("metrics.zig");
pub const profiler = @import("profiler.zig");

//Note(vasilis): Not sure if this is the proper way to do this.. I want the user
//to be able to call .init once in main, and then by simply importing
//this file (or the library) to wherever is needed then they can
//have access to the same global Profiler instance
pub var profiler_instance: profiler.Profiler = undefined;

test {
    _ = metrics;
    _ = profiler;
}
