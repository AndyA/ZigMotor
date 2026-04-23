const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;
const Pin = microzig.hal.gpio.Pin;

const sched = @import("../runtime/scheduler.zig");
const events = @import("../runtime/events.zig");

const Self = @This();

const POLL_TIME = 20000; // poll every 20ms
const DWELL_STEPS = 10; // light for 100ms

pin: Pin,
countdown: u32 = 0,

pub fn init(pin: Pin) Self {
    return Self{ .pin = pin };
}

pub fn schedule(self: *Self, slot: *sched.ScheduleSlot) void {
    slot.schedule(slot.now, task, self);
}

pub fn activate(self: *Self) void {
    if (self.countdown == 0)
        // currently sleeping
        self.pin.put(1);
    self.countdown = DWELL_STEPS;
}

fn task(ctx: *anyopaque, slot: *sched.ScheduleSlot) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.countdown != 0) {
        self.countdown -= 1;
        if (self.countdown == 0)
            self.pin.put(0);
    }
    slot.delay(POLL_TIME);
}
