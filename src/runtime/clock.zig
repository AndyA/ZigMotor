const std = @import("std");

const microzig = @import("../tools/bootstrap.zig").microzig;

const hal = microzig.hal;
const time = microzig.drivers.time;

pub const US_PER_TICK = 2;

pub fn microsecondsSinceBoot() time.Absolute {
    const sys_time = hal.time.get_time_since_boot().to_us();
    return time.Absolute.from_us(sys_time * US_PER_TICK);
}
