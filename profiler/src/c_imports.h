// This file is here for future reference of how to import C headers to Zig
// idiomatically Check build.zig for the rest
#define WIN32_LEAN_AND_MEAN 1

#if _WIN32

#include <windows.h>

#else

#include <sys/time.h>
#include <x86intrin.h>

#endif
