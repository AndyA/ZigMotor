// Simple scheduler
const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;

const assert = std.debug.assert;

pub const TaskHandler = fn (ctx: *anyopaque, slot: *ScheduleSlot) void;
pub const Never = time.Absolute.from_us(std.math.maxInt(u64));
pub const Now = time.Absolute.from_us(0);

pub const ScheduleSlot = struct {
    const Self = @This();

    now: time.Absolute = Now,
    then: time.Absolute = Now,
    deadline: time.Absolute = Never,
    handler: *const TaskHandler = undefined,
    context: *anyopaque = undefined,

    pub fn schedule(
        self: *Self,
        deadline: time.Absolute,
        handler: TaskHandler,
        context: *anyopaque,
    ) void {
        assert(self.deadline == Never);
        self.deadline = deadline;
        self.handler = handler;
        self.context = context;
    }

    pub fn poll(self: *Self, now: time.Absolute) bool {
        if (self.deadline.is_reached_by(now)) {
            self.now = now;
            self.then = self.deadline;
            self.deadline = Never;
            self.handler(self.context, self);
            return true;
        }

        return false;
    }
};

pub fn makeScheduler(comptime size: u8) type {
    return struct {
        const Self = @This();

        slots: [size]ScheduleSlot = @splat(.{}),

        pub fn poll(self: *Self, now: time.Absolute) bool {
            for (&self.slots) |*slot| {
                if (slot.poll(now)) return true;
            }
            return false;
        }

        pub fn pri(self: *Self, index: u8) *ScheduleSlot {
            return &self.slots[index];
        }
    };
}
