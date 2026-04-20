const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;
const Digital_IO = microzig.drivers.base.Digital_IO;

const sched = @import("../runtime/scheduler.zig");
const events = @import("../runtime/events.zig");

const Self = @This();

const POLL_TIME = 1000; // poll every 1ms
const DWELL_STEPS = 200; // light for 100ms

pin: Digital_IO,
countdown: u32 = 0,

pub fn init(pin: Digital_IO) !Self {
    try pin.set_direction(.output);
    return Self{ .pin = pin };
}

pub fn schedule(self: *Self, slot: *sched.ScheduleSlot) void {
    slot.schedule(slot.now, task, self);
}

pub fn activate(self: *Self) !void {
    if (self.countdown == 0)
        // currently sleeping
        try self.pin.write(.high);
    self.countdown = DWELL_STEPS;
}

fn task(ctx: *anyopaque, slot: *sched.ScheduleSlot) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.countdown != 0) {
        self.countdown -= 1;
        if (self.countdown == 0)
            try self.pin.write(.low);
    }
    slot.delay(POLL_TIME);
}
