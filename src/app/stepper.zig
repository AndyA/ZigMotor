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
        max_accel: f32, // rpm/m
        max_decel: f32, // rpm/m
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
        assert(config.max_accel > 0);
        assert(config.max_decel > 0);
        assert(config.min_rpm > 0);
        assert(config.max_rpm >= config.min_rpm);

        return .{ .config = config };
    }

    pub fn attach(self: *Self) void {
        const m = self.config.motor;
        m.rt_ee.addListener(onRTStateChange, self);
        m.setSpeed(0);
        m.setRemaining(0);
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
                self.last_tick = .from_us(0);
                self.tick(self.last_tick);
            }
        }
    }

    fn tick(self: *Self, now: time.Absolute) !void {
        // Minutes because our accel / decel are in rpm/m
        const elapsed: f32 = @as(f32, @floatFromInt(now.diff(self.last_tick).to_us())) /
            1_000_000 / 60;
        self.last_tick = now;

        const c = self.config;
        const m = c.motor;

        // Current speed. Always +ve
        const speed = m.speed;
        assert(speed >= 0);

        // How many steps are we off?
        const pos_error = self.set_point - m.current_position;

        if (pos_error == 0 and speed <= c.min_rpm) {
            // We've arrived
            m.setSpeed(0);
            m.setRemaining(0);
            try self.adviseState(.STOPPED);
            return;
        }

        // If the motor knows which way it's going use that otherwise set the direction
        // based on the direction we need to turn.
        const dir = switch (m.direction.step()) {
            -1, 1 => |d| d,
            0 => std.math.sign(pos_error),
            else => unreachable,
        };

        // Distance to destination in revolutions; -ve means we're going the wrong way
        const dest_dist = @as(f32, @floatFromInt(pos_error * dir)) /
            @as(f32, @floatFromInt(m.stepsPerRevolution()));
        // How far before we can stop?
        const stop_dist = (speed * speed) / (2 * c.max_decel);

        if (dest_dist <= stop_dist) {
            // Brake!
            m.setSpeed(@max(0, speed - c.max_decel * elapsed));
            m.setRemaing(dir * 2);
        } else {
            // Accelerate!
            m.setSpeed(@max(c.min_rpm, @min(c.max_rpm, speed + c.max_accel * elapsed)));
            m.setRemaining(std.math.sign(pos_error) * 2);
        }
    }

    fn onRTStateChange(ctx: *anyopaque, e: STSpin.RTEventPayload) !void {
        const self: *StepperController = @ptrCast(@alignCast(ctx));
        try self.tick(e.now);
    }
};
