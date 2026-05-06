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

    const Plan = struct {
        decay: u32,
        attack: u32,
        sustain: u32,
        release: u32,
    };

    const MIN_RPM_ADJ: f32 = 5;

    pub const Config = struct {
        motor: *STSpin,
        min_rpm: f32,
        max_rpm: f32,
        max_accel: f32, // rpm/m
        max_decel: f32, // rpm/m
    };

    pub const PartialConfig = struct {
        min_rpm: ?f32 = null,
        max_rpm: ?f32 = null,
        max_accel: ?f32 = null, // rpm/m
        max_decel: ?f32 = null, // rpm/m
    };

    pub const State = enum { STOPPED, MOVING };
    pub const RunMode = enum { SERVO, FREERUN, STOP };

    pub const Event = struct {
        target: *Self,
        state: State,
    };

    config: Config,
    original_config: Config,
    ee: events.Emitter(Event, 5) = .empty,
    state: State = .STOPPED,
    set_point: i64 = 0,
    last_tick: time.Absolute = .from_us(0),

    run_mode: RunMode = .SERVO,
    run_dir: STSpin.Direction = .UNKNOWN,

    // Cached values to avoid FP division
    recip_max_decel: f32 = undefined,
    revs_per_step: f32 = undefined,
    stop_decel_squared: f32 = undefined,

    fn checkConfig(config: Config) void {
        assert(config.max_accel > 0);
        assert(config.max_decel > 0);
        assert(config.min_rpm > 0);
        assert(config.max_rpm >= config.min_rpm);
    }

    pub fn init(config: Config) Self {
        checkConfig(config);
        return .{ .config = config, .original_config = config };
    }

    fn updatedCached(self: *Self) void {
        self.recip_max_decel = 1 / (2 * self.config.max_decel);
        self.revs_per_step = 1 / @as(f32, @floatFromInt(self.config.motor.stepsPerRevolution()));
        self.stop_decel_squared = square(self.config.min_rpm - MIN_RPM_ADJ);
    }

    pub fn setConfig(self: *Self, config: PartialConfig) void {
        var new_config = self.config;
        inline for (std.meta.fieldNames(PartialConfig)) |field| {
            if (@field(config, field)) |value|
                @field(new_config, field) = value;
        }
        checkConfig(new_config);
        self.config = new_config;
        self.updatedCached();
    }

    pub fn resetConfig(self: *Self) void {
        self.config = self.original_config;
        self.updatedCached();
    }

    pub fn attach(self: *Self) void {
        const m = self.config.motor;
        m.rt_ee.addListener(onRTStateChange, self);
        m.setSpeed(0);
        m.setRemaining(0);
        self.updatedCached();
    }

    fn adviseState(self: *Self, state: State) !void {
        if (self.state != state) {
            self.state = state;
            try self.ee.emit(.{ .target = self, .state = state });
        }
    }

    pub fn set(self: *Self, set_point: i64) void {
        self.set_point = set_point;
        self.run_mode = .SERVO;
    }

    pub fn run(self: *Self, run_dir: STSpin.Direction) void {
        assert(run_dir != .UNKNOWN);
        self.run_mode = .FREERUN;
        self.run_dir = run_dir;
    }

    pub fn stop(self: *Self) void {
        self.run_mode = .STOP;
    }

    fn stopMotor(self: *Self) !void {
        const m = self.config.motor;
        m.setSpeed(0);
        m.setRemaining(0);
        try self.adviseState(.STOPPED);
    }

    fn tick(self: *Self, now: time.Absolute) !void {
        @setFloatMode(.optimized);

        if (self.last_tick == time.Absolute.from_us(0)) {
            // Seed so that elapsed will be sane.
            self.last_tick = now;
            return;
        }

        // Minutes because our accel / decel are in rpm/m
        const elapsed: f32 = @as(f32, @floatFromInt(now.diff(self.last_tick).to_us())) *
            (@as(f32, 1) / @as(f32, 60_000_000));
        self.last_tick = now;

        const c = self.config;
        const m = c.motor;

        // How many steps are we off?
        const pos_error: i64 = switch (self.run_mode) {
            .SERVO => self.set_point - m.current_position,
            .FREERUN => switch (self.run_dir) {
                .CW => std.math.maxInt(i64),
                .CCW => std.math.minInt(i64),
                else => unreachable,
            },
            .STOP => 0,
        };

        const speed = @as(f32, @floatFromInt(m.speed)) / 100;

        if (pos_error == 0 and speed <= c.min_rpm) {
            // We've arrived
            try self.stopMotor();
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
        const dest_dist = @as(f32, @floatFromInt(pos_error)) * dir * self.revs_per_step;

        // How far will we travel before we can stop? We aim for MIN_RPM_ADJ slower than
        // we need to avoid overshoot. I don't fully understand the overshoot but I assume
        // it's caused be the cummulative errors in computed speed / actual speed. Shrug.
        const stop_dist = self.recip_max_decel * (square(speed) - self.stop_decel_squared);

        // print(
        //     "speed: {d}, error: {d}, dir: {d}, dest_dist: {d}, stop_dist: {d}, ",
        //     .{ m.getActualSpeed(), pos_error, dir, dest_dist, stop_dist },
        // );

        if (dest_dist <= stop_dist) {
            // Brake!
            m.setSpeedFloat(@max(c.min_rpm, speed - c.max_decel * elapsed));
            // Do we need to reverse or stop?
            if (speed <= c.min_rpm and std.math.sign(pos_error) != std.math.sign(dir))
                m.setRemaining(-dir * 2)
            else
                m.setRemaining(dir * 2);

            // print("brake: {d}\n", .{m.steps_remaining});
        } else {
            // Accelerate!
            m.setSpeedFloat(@max(c.min_rpm, @min(c.max_rpm, speed + c.max_accel * elapsed)));
            m.setRemaining(@as(i32, @intCast(std.math.sign(pos_error))) * 2);
            // print("accelerate: {d}\n", .{m.steps_remaining});
        }
    }

    fn onRTStateChange(ctx: *anyopaque, e: STSpin.RTEventPayload) !void {
        const self: *StepperController = @ptrCast(@alignCast(ctx));
        try self.tick(e.now);
    }
};
