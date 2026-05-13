const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("../tools/bootstrap.zig").microzig;
const time = microzig.drivers.time;

pub const EveryCounter = struct {
    const Self = @This();

    every: u32,
    count: u32 = 0,

    pub fn poll(self: *Self) bool {
        assert(self.count < self.every);
        self.count += 1;
        if (self.count == self.every) {
            self.count = 0;
            return true;
        }

        return false;
    }
};

pub const EveryTimer = struct {
    const Self = @This();

    every: time.Duration,
    deadline: time.Absolute = .from_us(0),

    pub fn poll(self: *Self, now: time.Absolute) bool {
        if (self.deadline.is_reached_by(now)) {
            self.deadline = self.deadline.add_duration(self.every);
            return true;
        }

        return false;
    }
};
