const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;

const sched = @import("runtime/scheduler.zig");
const events = @import("runtime/events.zig");
const clock = @import("runtime/clock.zig");

const Blinker = @import("drivers/Blinker.zig");
const Alert = @import("drivers/Alert.zig");
const Indicator = @import("drivers/Indicator.zig");
const STSpin = @import("drivers/STSpin.zig");

const Sequencer = struct {
    const Self = @This();

    pub const Step = struct {
        speed: f32 = 300,
        steps: i32,
    };
    const MaxSteps = 100;

    steps: [MaxSteps]Step = undefined,
    used: u16 = 0,
    current: u16 = 0,
    alert: ?*Alert = null,

    pub const empty: Self = .{};

    pub fn attach(self: *Self, stepper: *STSpin) void {
        stepper.state_ee.addListener(onStateChange, self);
    }

    pub fn addSteps(self: *Self, steps: []const Step) void {
        assert(self.used + steps.len <= MaxSteps);
        @memcpy(self.steps[self.used .. self.used + steps.len], steps);
        self.used += @intCast(steps.len);
    }

    fn onStateChange(ctx: *anyopaque, e: STSpin.EventPayload) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        switch (e.state) {
            .IDLE => {
                if (self.used == 0) return;
                if (self.alert) |alert|
                    alert.activate();
                const step = self.steps[self.current];
                e.target.setSpeed(step.speed);
                e.target.rotate(step.steps);
                self.current += 1;
                if (self.current >= self.used)
                    self.current = 0;
            },
            else => {},
        }
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

    const steps = &[_]Sequencer.Step{
        .{ .speed = 60.00, .steps = 400 }, // M0 / M8
        .{ .speed = 120.00, .steps = -800 }, // M1
        .{ .speed = 240.00, .steps = 1600 }, // M2
        .{ .speed = 480.00, .steps = -3200 }, // M3 unstable after this
        .{ .speed = 960.00, .steps = 6400 }, // M4
        .{ .speed = 1920.00, .steps = -12800 }, // M5 can't do these
        .{ .speed = 3840.00, .steps = 25600 }, // M6
        .{ .speed = 7680.00, .steps = -51200 }, // M7
    };

    blue1.activate();

    var sequencer: Sequencer = .{ .alert = &red2 };
    sequencer.addSteps(steps);
    sequencer.attach(&stepper);

    try stepper.start(scheduler.pri(0));

    var monitor: SchedulerMonitor = .{
        .indicator = Indicator.init(pins.led),
    };

    const hook = monitor.hook();
    while (true) {
        _ = try scheduler.pollWithHook(clock.microsecondsSinceBoot(), hook);
    }
}

test {
    _ = @import("runtime/scheduler.zig");
    _ = @import("runtime/events.zig");
    _ = @import("runtime/ticker.zig");
    _ = @import("drivers/STSpin.zig");
    _ = @import("app/stepper.zig");
}
