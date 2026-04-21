const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;
const Digital_IO = microzig.drivers.base.Digital_IO;

const sched = @import("../runtime/scheduler.zig");
const events = @import("../runtime/events.zig");

const Self = @This();

pin: Digital_IO,

state: Digital_IO.State = .low,

pub fn init(pin: Digital_IO) !Self {
    try pin.set_direction(.output);
    try pin.write(.low);
    return Self{ .pin = pin };
}

pub fn on(self: Self) !void {
    try self.pin.write(.high);
}

pub fn off(self: Self) !void {
    try self.pin.write(.low);
}
