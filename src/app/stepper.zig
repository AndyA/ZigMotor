const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;

const microzig = @import("../tools/bootstrap.zig").microzig;

const time = microzig.drivers.time;

const events = @import("../runtime/events.zig");
const STSpin = @import("../drivers/STSpin.zig");
const every = @import("../runtime/every.zig");

pub const StepperController = struct {
    const Self = @This();

    const MIN_RPM_ADJ: f32 = 5;

    pub const Config = struct {
        motor: *STSpin,
        min_rpm: f32,
        max_rpm: f32,
        max_delta: f32, // rate limits initial acceleration
        rate: f32, // rpm / (rpm ^ 2)
    };

    pub const State = enum { STOPPED, MOVING };
    pub const RunMode = enum { SERVO, FREERUN, STOP };

    pub const Event = struct {
        target: *Self,
        state: State,
    };

    config: Config,
    ee: events.Emitter(Event, 5) = .empty,
    state: State = .STOPPED,
    set_point: i64 = 0,

    rpm: f32 = 0,
    stopping_distance: u32 = 0, // number of steps to stop

    run_mode: RunMode = .SERVO,
    run_dir: STSpin.Direction = .UNKNOWN,

    pacer: every.EveryTimer = .{ .every = .from_us(1_000_000) },

    fn checkConfig(config: Config) void {
        assert(config.min_rpm > 0);
        assert(config.max_rpm >= config.min_rpm);
    }

    pub fn init(config: Config) Self {
        checkConfig(config);
        return .{ .config = config };
    }

    pub fn attach(self: *Self) void {
        const m = self.config.motor;
        m.rt_ee.addListener(onRTStateChange, self);
        m.setSpeed(0);
        m.setRemaining(0);
    }

    pub fn set(self: *Self, set_point: i64) void {
        self.set_point = set_point;
        self.run_mode = .SERVO;
    }

    pub fn run(self: *Self, run_dir: STSpin.Direction) void {
        assert(run_dir != .UNKNOWN);
        self.run_dir = run_dir;
        self.run_mode = .FREERUN;
    }

    pub fn stop(self: *Self) void {
        self.run_mode = .STOP;
    }

    fn adviseState(self: *Self, state: State) !void {
        if (self.state != state) {
            self.state = state;
            try self.ee.emit(.{ .target = self, .state = state });
        }
    }

    fn setSpeed(self: *Self, rpm: f32) void {
        self.config.motor.setSpeedFloat(rpm);
        self.rpm = rpm;
    }

    fn rpmDelta(self: *const Self) f32 {
        const c = self.config;
        const delta = c.rate / (self.rpm * self.rpm);
        return @min(c.max_delta, delta);
    }

    fn tick(self: *Self, e: STSpin.RTEventPayload) !void {
        const c = self.config;
        const m = c.motor;

        // How many steps are we off?
        const pos_error: i64 = switch (self.run_mode) {
            .SERVO => self.set_point - m.current_position,
            .FREERUN => switch (self.run_dir) {
                // Don't have to be as huge as an i64 - just big enough
                // to make sure we don't consider slowing down.
                .CW => @as(i64, @intCast(std.math.maxInt(i32))),
                .CCW => -@as(i64, @intCast(std.math.maxInt(i32))),
                else => unreachable,
            },
            .STOP => 0,
        };

        if (self.pacer.poll(e.now)) {
            std.log.info(
                "state: {s:>7}, run_mode: {s:>7}, direction: {s:>3}, " ++
                    "rpm: {d:>7.2}, set_point: {d:>6}, current: {d:>6}, " ++
                    "pos_error: {d:>6}, stopping_distance: {d:>6}",
                .{
                    @tagName(self.state),
                    @tagName(self.run_mode),
                    @tagName(m.direction),
                    self.rpm,
                    self.set_point,
                    m.current_position,
                    pos_error,
                    self.stopping_distance,
                },
            );
        }

        switch (self.state) {
            .STOPPED => {
                assert(!e.running);
                if (pos_error != 0) {
                    // Need to move
                    self.stopping_distance = 0;
                    self.setSpeed(c.min_rpm);
                    const step: i32 = std.math.sign(pos_error);
                    m.setRemaining(step);
                    try self.adviseState(.MOVING);
                }
            },
            .MOVING => {
                assert(e.running);
                if (pos_error == 0 and self.stopping_distance == 0) {
                    // we've arrived
                    m.setRemaining(0);
                    try self.adviseState(.STOPPED);
                    return;
                }

                // If we're still moving at speed the ambient direction is the motor's
                // current direction; otherwise it's up for grabs and we set it to the
                // direction we want to go.
                const direction = if (self.stopping_distance == 0)
                    STSpin.Direction.from_error(pos_error)
                else
                    m.direction;

                const step = direction.step(i32);

                // Error relative to ambient direction: -ve means it's behind us
                const rel_error = pos_error * step;

                if (self.stopping_distance >= rel_error) {
                    // Need to slow down
                    self.setSpeed(@max(c.min_rpm, self.rpm - self.rpmDelta()));
                    self.stopping_distance -= 1;
                } else if (self.rpm < c.max_rpm) {
                    // Need to speed up
                    self.setSpeed(@min(c.max_rpm, self.rpm + self.rpmDelta()));
                    self.stopping_distance += 1;
                }

                m.setRemaining(step);
            },
        }
    }

    fn onRTStateChange(ctx: *anyopaque, e: STSpin.RTEventPayload) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.tick(e);
    }
};
