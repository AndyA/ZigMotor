const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;
const Pin = microzig.hal.gpio.Pin;

const sched = @import("../runtime/scheduler.zig");
const events = @import("../runtime/events.zig");

const Self = @This();

pin: Pin,

pub fn init(pin: Pin) Self {
    pin.put(0);
    return Self{ .pin = pin };
}

pub fn on(self: Self) void {
    self.pin.put(1);
}

pub fn off(self: Self) void {
    self.pin.put(0);
}
