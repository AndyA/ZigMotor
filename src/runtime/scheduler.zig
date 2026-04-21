// Simple scheduler
const std = @import("std");

const microzig = if (@import("builtin").is_test)
    @import("../testing/microzig.zig")
else
    @import("microzig");

const callback = @import("callback.zig");

const time = microzig.drivers.time;

const assert = std.debug.assert;

pub const TaskHandler = fn (ctx: *anyopaque, slot: *ScheduleSlot) anyerror!void;
pub const Now = time.Absolute.from_us(0);
pub const Never = time.Absolute.from_us(std.math.maxInt(u64));

pub const SchedulerState = enum { IDLE, RUNNING };
pub const SchedulerHook = callback.makeCallback(SchedulerState);

/// A single scheduler slot
pub const ScheduleSlot = struct {
    const Self = @This();

    now: time.Absolute = Now,
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

    pub fn delay(self: *Self, delay_us: u64) void {
        assert(self.deadline == Never);
        self.deadline = self.now.add_duration(time.Duration.from_us(delay_us));
    }

    pub fn pollWithHook(self: *Self, now: time.Absolute, hook: ?SchedulerHook) !bool {
        if (self.deadline.is_reached_by(now)) {
            self.now = now;
            self.deadline = Never;
            if (hook) |h| try h.advise(.RUNNING);
            try self.handler(self.context, self);
            if (hook) |h| try h.advise(.IDLE);
            return true;
        }

        return false;
    }

    pub fn poll(self: *Self, now: time.Absolute) !bool {
        return try self.pollWithHook(now, null);
    }
};

pub fn makeScheduler(comptime size: u8) type {
    return struct {
        const Self = @This();
        pub const empty: Self = .{};

        slots: [size]ScheduleSlot = @splat(.{}),

        pub fn pollWithHook(self: *Self, now: time.Absolute, hook: ?SchedulerHook) !bool {
            for (&self.slots) |*slot| {
                if (try slot.pollWithHook(now, hook)) return true;
            }
            return false;
        }

        pub fn poll(self: *Self, now: time.Absolute) !bool {
            return try self.pollWithHook(now, null);
        }

        pub fn pri(self: *Self, index: i9) *ScheduleSlot {
            if (index < 0)
                return &self.slots[@intCast(size + index)]
            else
                return &self.slots[@intCast(index)];
        }
    };
}
