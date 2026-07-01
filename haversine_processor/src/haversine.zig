// ========================================================================
//
// (C) Copyright 2023 by Molly Rocket, Inc., All Rights Reserved.
//
// This software is provided 'as-is', without any express or implied
// warranty. In no event will the authors be held liable for any damages
// arising from the use of this software.
//
// Please see https://computerenhance.com for more information
//
// ========================================================================
//
// ========================================================================
// LISTING 65
// ========================================================================
//
// NOTE(vasilis): this is a 'translated' version in zig but is identical to the
//                  original other than syntax differences.

const math = @import("std").math;

// NOTE: EarthRadius is expected to be 6372.8, might aswell expose it here
pub const EARTH_RADIUS: f64 = 6372.8;

fn square(a: f64) f64 {
    return a * a;
}

fn radiansFromDegrees(degrees: f64) f64 {
    return 0.01745329251994329577 * degrees;
}

pub fn referenceHaversine(x0: f64, y0: f64, x1: f64, y1: f64, EarthRadius: f64) f64 {
    var lat1 = y0;
    var lat2 = y1;
    const lon1 = x0;
    const lon2 = x1;

    const dLat = radiansFromDegrees(lat2 - lat1);
    const dLon = radiansFromDegrees(lon2 - lon1);
    lat1 = radiansFromDegrees(lat1);
    lat2 = radiansFromDegrees(lat2);

    const a = square(math.sin(dLat / 2.0)) + math.cos(lat1) * math.cos(lat2) * square(math.sin(dLon / 2.0));
    const c = 2.0 * math.asin(math.sqrt(a));

    const result = EarthRadius * c;

    return result;
}
