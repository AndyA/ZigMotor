const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;

const microzig = @import("../tools/bootstrap.zig").microzig;

const time = microzig.drivers.time;

const events = @import("../runtime/events.zig");
const STSpin = @import("../drivers/STSpin.zig");

fn square(v: f32) f32 {
    return v * v;
}

pub const StepperController = struct {
    const Self = @This();

    const MIN_RPM_ADJ: f32 = 5;

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

    pub fn set(self: *Self, set_point: i64) void {
        self.set_point = set_point;
    }

    fn tick(self: *Self, now: time.Absolute) !void {
        if (self.last_tick == time.Absolute.from_us(0)) {
            // Seed so that elapsed will be sane.
            self.last_tick = now;
            return;
        }

        // Minutes because our accel / decel are in rpm/m
        const elapsed: f32 = @as(f32, @floatFromInt(now.diff(self.last_tick).to_us())) /
            1_000_000 / 60;
        self.last_tick = now;

        const c = self.config;
        const m = c.motor;

        // How many steps are we off?
        const pos_error = self.set_point - m.current_position;

        if (pos_error == 0 and m.speed <= c.min_rpm) {
            // We've arrived
            m.setSpeed(0);
            m.setRemaining(0);
            try self.adviseState(.STOPPED);
            return;
        }

        try self.adviseState(.MOVING);

        // If the motor knows which way it's going use that otherwise set the direction
        // based on the direction we need to turn.
        const dir = switch (m.direction.step()) {
            -1, 1 => |d| d,
            0 => std.math.sign(pos_error),
            else => unreachable,
        };

        // Distance to destination in revolutions; -ve means we're going the wrong way
        const dest_dist = @as(f32, @floatFromInt(pos_error * dir)) /
            m.floatStepsPerRevolution();

        // How far will we travel before we can stop? We aim for MIN_RPM_ADJ slower than
        // we need to avoid overshoot. I don't fully understand the overshoot but I assume
        // it's caused be the cummulative errors in computed speed / actual speed. Shrug.
        const stop_dist = (square(m.speed) - square(self.config.min_rpm - MIN_RPM_ADJ)) /
            (2 * c.max_decel);

        // print(
        //     "speed: {d}, error: {d}, dir: {d}, dest_dist: {d}, stop_dist: {d}, ",
        //     .{ m.getActualSpeed(), pos_error, dir, dest_dist, stop_dist },
        // );

        if (dest_dist <= stop_dist) {
            // Brake!
            m.setSpeed(@max(c.min_rpm, m.speed - c.max_decel * elapsed));
            // Do we need to reverse?
            if (m.speed <= c.min_rpm and std.math.sign(pos_error) != std.math.sign(dir))
                m.setRemaining(-dir * 2)
            else
                m.setRemaining(dir * 2);
            // print("brake: {d}\n", .{m.steps_remaining});
        } else {
            // Accelerate!
            m.setSpeed(@max(c.min_rpm, @min(c.max_rpm, m.speed + c.max_accel * elapsed)));
            m.setRemaining(@as(i32, @intCast(std.math.sign(pos_error))) * 2);
            // print("accelerate: {d}\n", .{m.steps_remaining});
        }
    }

    fn onRTStateChange(ctx: *anyopaque, e: STSpin.RTEventPayload) !void {
        const self: *StepperController = @ptrCast(@alignCast(ctx));
        try self.tick(e.now);
    }
};
