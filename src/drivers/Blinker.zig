const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;
const Digital_IO = microzig.drivers.base.Digital_IO;

const sched = @import("../runtime/scheduler.zig");
const events = @import("../runtime/events.zig");

const Self = @This();

pin: Digital_IO,
delay: time.Duration,

state: Digital_IO.State = .low,

pub fn init_us(pin: Digital_IO, delay_us: u64) !Self {
    try pin.set_direction(.output);
    return Self{
        .pin = pin,
        .delay = time.Duration.from_us(delay_us),
    };
}

pub fn schedule(self: *Self, slot: *sched.ScheduleSlot) void {
    const deadline = slot.now.add_duration(self.delay);
    slot.schedule(deadline, task, self);
}

fn task(ctx: *anyopaque, slot: *sched.ScheduleSlot) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.state = self.state.invert();
    try self.pin.write(self.state);
    self.schedule(slot);
}
