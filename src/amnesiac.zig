// Simple scheduler
const std = @import("std");
const microzig = @import("microzig");
const time = microzig.drivers.time;

const assert = std.debug.assert;

pub fn Amnesiac(comptime slots: u8) type {
    return struct {
        const Self = @This();
        pub const TaskHandler = fn (ctx: *anyopaque, amnesiac: *Self) void;
        pub const Never = time.Absolute.from_us(std.math.maxInt(u64));
        pub const Now = time.Absolute.from_us(0);

        now: time.Absolute = Now,

        deadlines: [slots]time.Absolute = @splat(Never),
        handlers: [slots]*const TaskHandler = undefined,
        contexts: [slots]*anyopaque = undefined,

        pub fn init() Self {
            return .{};
        }

        /// Schedule a task
        pub fn schedule(
            self: *Self,
            slot: u8,
            deadline: time.Absolute,
            handler: TaskHandler,
            context: *anyopaque,
        ) void {
            assert(slot < slots);
            assert(self.deadlines[slot] == Never);

            self.deadlines[slot] = deadline;
            self.handlers[slot] = handler;
            self.contexts[slot] = context;
        }

        /// Run a single iteration of the task loop
        pub fn pump(self: *Self, now: time.Absolute) bool {
            self.now = now;

            for (self.deadlines, 0..) |deadline, slot| {
                if (deadline.is_reached_by(self.now)) {
                    self.deadlines[slot] = Never;
                    self.handlers[slot](self.contexts[slot], self);
                    return true;
                }
            }

            return false;
        }
    };
}
