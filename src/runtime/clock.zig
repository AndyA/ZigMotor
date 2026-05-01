const std = @import("std");

const microzig = @import("../tools/bootstrap.zig").microzig;

const hal = microzig.hal;
const time = microzig.drivers.time;

pub fn microsecondsSinceBoot() time.Absolute {
    return hal.time.get_time_since_boot();
}
