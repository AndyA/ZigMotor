const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;
const time = microzig.drivers.time;

const sched = @import("runtime/scheduler.zig");
const events = @import("runtime/events.zig");
const clock = @import("runtime/clock.zig");

const Blinker = @import("drivers/Blinker.zig");
const Alert = @import("drivers/Alert.zig");
const Indicator = @import("drivers/Indicator.zig");
const STSpin = @import("drivers/STSpin.zig");

pub const Now = time.Absolute.from_us(0);
pub const Never = time.Absolute.from_us(std.math.maxInt(u64));

const Ramper = struct {
    const Self = @This();

    pub const Config = struct {
        motor: *STSpin,
        min_rpm: f32,
        max_rpm: f32,
        max_delta: f32,
        rate: f32,
        rest_time: u32, // µS
        cruise_time: u32, // µS
    };

    pub const State = enum { INIT, REST, ACCEL, CRUISE, DECEL };

    config: Config,
    state: State = .INIT,
    rpm: f32 = 0,
    deadline: time.Absolute = Never,

    pub fn init(config: Config) Self {
        return .{ .config = config };
    }

    pub fn attach(self: *Self) void {
        const m = self.config.motor;
        m.rt_ee.addListener(onRTStateChange, self);
        m.setSpeed(0);
        m.setRemaining(0);
    }

    pub fn start(self: *Self) void {
        if (self.state == .INIT) {
            self.state = .REST;
            self.deadline = Now;
            self.rpm = self.config.min_rpm;
        }
    }

    fn rpmDelta(self: *const Self) f32 {
        const c = self.config;
        const delta = c.rate / (self.rpm * self.rpm);
        return @min(c.max_delta, delta);
    }

    fn setDeadline(self: *Self, now: time.Absolute, delay_us: u32) void {
        self.deadline = now.add_duration(time.Duration.from_us(delay_us));
    }

    fn setSpeed(self: *Self, rpm: f32) void {
        self.config.motor.setSpeedFloat(rpm);
        self.rpm = rpm;
    }

    fn tick(self: *Self, now: time.Absolute) !void {
        const c = self.config;

        if (self.state != .INIT)
            c.motor.setRemaining(2);

        switch (self.state) {
            .INIT => {},
            .REST => {
                if (self.deadline.is_reached_by(now))
                    self.state = .ACCEL;
            },
            .ACCEL => {
                const next_rpm = self.rpm + self.rpmDelta();
                if (next_rpm < c.max_rpm) {
                    self.setSpeed(next_rpm);
                    return;
                }

                self.setSpeed(c.max_rpm);
                self.setDeadline(now, c.cruise_time);
                self.state = .CRUISE;
            },
            .CRUISE => {
                if (self.deadline.is_reached_by(now))
                    self.state = .DECEL;
            },
            .DECEL => {
                const next_rpm = self.rpm - self.rpmDelta();
                if (next_rpm > c.min_rpm) {
                    self.setSpeed(next_rpm);
                    return;
                }

                self.setSpeed(0);
                self.setDeadline(now, c.rest_time);
                self.state = .REST;
            },
        }
    }

    fn onRTStateChange(ctx: *anyopaque, e: STSpin.RTEventPayload) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.tick(e.now);
    }
};

const Scheduler = sched.makeScheduler(8);

const SchedulerMonitor = struct {
    const Self = @This();
    indicator: Indicator,

    pub fn hook(self: *Self) sched.SchedulerHook {
        return .{ .context = self, .handler = callback };
    }

    fn callback(ctx: *anyopaque, state: sched.SchedulerState) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        switch (state) {
            .IDLE => self.indicator.on(),
            .RUNNING => self.indicator.off(),
        }
    }
};

// Compile-time pin configuration
const pin_config = hal.pins.GlobalConfiguration{
    .GPIO12 = .{ .name = "blue1", .direction = .out },
    .GPIO13 = .{ .name = "blue2", .direction = .out },
    .GPIO14 = .{ .name = "red1", .direction = .out },
    .GPIO15 = .{ .name = "red2", .direction = .out },

    .GPIO21 = .{ .name = "dir", .direction = .out },
    .GPIO20 = .{ .name = "step", .direction = .out },
    .GPIO19 = .{ .name = "mode1", .direction = .out },
    .GPIO18 = .{ .name = "mode2", .direction = .out },
    .GPIO17 = .{ .name = "fault", .direction = .in, .pull = .up },
    .GPIO16 = .{ .name = "reset", .direction = .out },

    .GPIO25 = .{ .name = "led", .direction = .out },
    .GPIO26 = .{ .name = "busy", .direction = .out },
};

pub fn main() !void {
    @setEvalBranchQuota(std.math.maxInt(usize));
    const pins = pin_config.apply();

    var scheduler: Scheduler = .empty;

    var blue1 = Alert.init(pins.blue1);
    blue1.schedule(scheduler.pri(-2));

    var red2 = Alert.init(pins.red2);
    red2.schedule(scheduler.pri(-5));

    var stepper: STSpin = .init(.{
        .step_pin = pins.step,
        .dir_pin = pins.dir,
        .reset_pin = pins.reset,
        .en_fault_pin = pins.fault,
        .mode1_pin = pins.mode1,
        .mode2_pin = pins.mode2,
    });
    stepper.setMicrostep(4);

    blue1.activate();

    var ramper: Ramper = .init(.{
        .motor = &stepper,
        .min_rpm = 5,
        .max_rpm = 500,
        .max_delta = 5,
        .rate = 20000,
        .rest_time = 2_000_000,
        .cruise_time = 5_000_000,
    });

    ramper.attach();
    try stepper.start(scheduler.pri(0));
    ramper.start();

    var monitor: SchedulerMonitor = .{
        .indicator = Indicator.init(pins.busy),
    };

    const hook = monitor.hook();
    while (true) {
        _ = try scheduler.pollWithHook(clock.microsecondsSinceBoot(), hook);
    }
}
