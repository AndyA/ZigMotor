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
const stepper = @import("app/stepper.zig");
const StepperController = stepper.StepperController;

const Sequencer = struct {
    const Self = @This();

    pub const Step = struct {
        set_point: i64,
    };
    const MaxSteps = 100;

    steps: [MaxSteps]Step = undefined,
    used: u16 = 0,
    current: u16 = 0,
    alert: ?*Alert = null,

    pub const empty: Self = .{};

    pub fn attach(self: *Self, controller: *StepperController) void {
        controller.attach();
        controller.ee.addListener(onStateChange, self);
        self.nextStep(controller);
    }

    pub fn addSteps(self: *Self, steps: []const Step) void {
        assert(self.used + steps.len <= MaxSteps);
        @memcpy(self.steps[self.used .. self.used + steps.len], steps);
        self.used += @intCast(steps.len);
    }

    fn nextStep(self: *Self, controller: *StepperController) void {
        if (self.used == 0) return;
        if (self.alert) |alert|
            alert.activate();
        const step = self.steps[self.current];
        controller.set(step.set_point);
        self.current += 1;
        if (self.current >= self.used)
            self.current = 0;
    }

    fn onStateChange(ctx: *anyopaque, e: StepperController.Event) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        switch (e.state) {
            .STOPPED => {
                self.nextStep(e.target);
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
    .GPIO27 = .{ .name = "debug", .direction = .out },

    .GPIO25 = .{ .name = "led", .direction = .out },
    .GPIO26 = .{ .name = "busy", .direction = .out },
};

pub fn main() !void {
    @setEvalBranchQuota(std.math.maxInt(usize));
    const pins = pin_config.apply();
    var scheduler: Scheduler = .empty;

    const busy = Indicator.init(pins.busy);
    busy.on();

    var red2 = Alert.init(pins.red2);
    red2.schedule(scheduler.pri(1));
    var blue1 = Alert.init(pins.blue1);
    blue1.schedule(scheduler.pri(2));

    var motor: STSpin = .init(.{
        .step_pin = pins.step,
        .dir_pin = pins.dir,
        .reset_pin = pins.reset,
        .en_fault_pin = pins.fault,
        .mode1_pin = pins.mode1,
        .mode2_pin = pins.mode2,
        .debug_pin = pins.debug,
    });

    var controller = StepperController.init(.{
        .motor = &motor,
        .min_rpm = 5,
        .max_rpm = 600,
        .max_delta = 5,
        .rate = 20000,
    });
    controller.attach();

    const STEPS_PER_REVOLUTION = 200;
    const MICROSTEP = 4;

    // microsteps per revolution
    const USPR = STEPS_PER_REVOLUTION * MICROSTEP;

    const steps = &[_]Sequencer.Step{
        .{ .set_point = USPR * 1 },
        .{ .set_point = -USPR * 1 },
        .{ .set_point = USPR * 2 },
        .{ .set_point = -USPR * 2 },
        .{ .set_point = USPR * 4 },
        .{ .set_point = -USPR * 4 },
        .{ .set_point = USPR * 8 },
        .{ .set_point = -USPR * 8 },
        .{ .set_point = USPR * 16 },
        .{ .set_point = -USPR * 16 },
        .{ .set_point = USPR * 32 },
        .{ .set_point = -USPR * 32 },
    };

    blue1.activate();

    var sequencer: Sequencer = .{ .alert = &red2 };
    sequencer.addSteps(steps);
    sequencer.attach(&controller);

    motor.setMicrostep(MICROSTEP);
    try motor.start(scheduler.pri(0));

    var monitor: SchedulerMonitor = .{
        .indicator = busy,
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
