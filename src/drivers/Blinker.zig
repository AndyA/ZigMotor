const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;
const Pin = microzig.hal.gpio.Pin;

const sched = @import("../runtime/scheduler.zig");
const events = @import("../runtime/events.zig");

const Self = @This();

pin: Pin,
delay: time.Duration,

pub fn init_us(pin: Pin, delay_us: u64) Self {
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
    self.pin.toggle();
    self.schedule(slot);
}
