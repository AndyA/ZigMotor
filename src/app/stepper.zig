const std = @import("std");
const assert = std.debug.assert;

const microzig = if (@import("builtin").is_test)
    @import("../testing/microzig.zig")
else
    @import("microzig");

const time = microzig.drivers.time;

const events = @import("../runtime/events.zig");
const STSpin = @import("../drivers/STSpin.zig");

pub const StepperController = struct {
    const Self = @This();
    pub const Config = struct {
        motor: *STSpin,
        min_rpm: f32,
        max_rpm: f32,
        max_accel: f32, // rpm/s
        max_decel: f32, // rpm/s
    };

    pub const State = enum { STOPPED, MOVING };

    pub const Event = struct {
        target: *Self,
        state: State,
    };

    config: Config,
    ee: events.Emitter(Event, 5) = .empty,
    state: State = .STOPPED,
    set_point: i64 = 0,
    last_tick: time.Absolute = .from_us(0),

    pub fn init(config: Config) Self {
        return .{ .config = config };
    }

    pub fn attach(self: *Self) void {
        self.config.motor.state_ee.addListener(onStateChange, self);
        self.config.motor.rt_ee.addListener(onRTStateChange, self);
    }

    fn adviseState(self: *Self, state: State) !void {
        if (self.state != state) {
            self.state = state;
            try self.ee.emit(.{ .target = self, .state = state });
        }
    }

    pub fn set(self: *Self, set_point: i64) !void {
        if (self.set_point != set_point) {
            self.set_point = set_point;
            if (self.state == .STOPPED) {
                try self.adviseState(.MOVING);
                self.tick(self.last_tick);
            }
        }
    }

    fn tick(self: *Self, now: time.Absolute) !void {
        // const elapsed = now.diff(self.last_tick).to_us();
        self.last_tick = now;

        const motor = self.config.motor;
        // const dir = motor.direction.step();
        // // Distance to destination; -ve means we're going the wrong way
        // const to_dest = (self.set_point - motor.current_position) * dir;

        // Current speed. Always +ve
        const speed = motor.speed;
        assert(speed >= 0);

        if (self.set_point == motor.current_position and speed <= self.config.min_rpm) {
            motor.setRemaining(0);
            motor.setSpeed(0);
            try self.adviseState(.STOPPED);
            return;
        }

        // if (to_dest < 0) {
        //     // We've passed it; decelerate as hard as we can
        //     const decel = @max(0, @as(f32, @floatCast(elapsed)) * self.config.max_decel);
        //     _ = decel;
        // } else {}

        // const stopping_distance = (speed * speed) / 2 * self.config.max_decel;
        // _ = stopping_distance;
    }

    fn onStateChange(ctx: *anyopaque, e: STSpin.EventPayload) !void {
        const self: *StepperController = @ptrCast(@alignCast(ctx));
        _ = self;
        _ = e;
    }

    fn onRTStateChange(ctx: *anyopaque, e: STSpin.RTEventPayload) !void {
        const self: *StepperController = @ptrCast(@alignCast(ctx));
        try self.tick(e.now);
    }
};
