const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;
const GPIO_Device = hal.drivers.GPIO_Device;

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
                    try alert.activate();
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

    fn callback(ctx: *anyopaque, state: sched.SchedulerState) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        switch (state) {
            .IDLE => try self.indicator.on(),
            .RUNNING => try self.indicator.off(),
        }
    }
};

pub fn main() !void {
    var scheduler: Scheduler = .empty;

    var pins: struct {
        blue1: GPIO_Device,
        blue2: GPIO_Device,
        red1: GPIO_Device,
        red2: GPIO_Device,

        dir: GPIO_Device,
        step: GPIO_Device,
        mode1: GPIO_Device,
        mode2: GPIO_Device,
        fault: GPIO_Device,
        reset: GPIO_Device,

        led: GPIO_Device,
    } = undefined;

    const gpio_numbers = .{
        12, // blue 1
        13, // blue 2
        14, // red 1
        15, // red 2

        21, // dir
        20, // step
        19, // mode 1
        18, // mode 2
        17, // fault
        16, // reset

        25, // board led
    };

    inline for (std.meta.fields(@TypeOf(pins)), gpio_numbers) |field, num| {
        const pin = hal.gpio.num(num);
        pin.set_function(.sio);
        @field(pins, field.name) = GPIO_Device.init(pin);
    }

    // var led = try Blinker.init_us(pins.led.digital_io(), 125_000);
    // led.schedule(scheduler.pri(-1));

    var blue1 = try Alert.init(pins.blue1.digital_io());
    blue1.schedule(scheduler.pri(-2));
    // var blue2 = try Alert.init(pins.blue2.digital_io());
    // blue2.schedule(scheduler.pri(-3));

    // var red1 = try Alert.init(pins.red1.digital_io());
    // red1.schedule(scheduler.pri(-4));
    var red2 = try Alert.init(pins.red2.digital_io());
    red2.schedule(scheduler.pri(-5));

    var stepper: STSpin = .init(.{
        .step_pin = pins.step.digital_io(),
        .dir_pin = pins.dir.digital_io(),
        .reset_pin = pins.reset.digital_io(),
        .en_fault_pin = pins.fault.digital_io(),
        .mode1_pin = pins.mode1.digital_io(),
        .mode2_pin = pins.mode2.digital_io(),
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

    try blue1.activate();
    // try blue2.activate();
    // try red1.activate();
    // try red2.activate();

    var sequencer: Sequencer = .{ .alert = &red2 };
    sequencer.addSteps(steps);
    sequencer.attach(&stepper);

    try stepper.start(scheduler.pri(0));

    var monitor: SchedulerMonitor = .{
        .indicator = try Indicator.init(pins.led.digital_io()),
    };

    while (true) {
        _ = try scheduler.pollWithHook(
            clock.microsecondsSinceBoot(),
            monitor.hook(),
        );
    }
}

test {
    _ = @import("runtime/scheduler.zig");
    _ = @import("runtime/events.zig");
    _ = @import("runtime/ticker.zig");
    _ = @import("drivers/STSpin.zig");
    _ = @import("app/stepper.zig");
}
