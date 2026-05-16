const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;

const logging = @import("runtime/logging.zig");
const sched = @import("runtime/scheduler.zig");
const events = @import("runtime/events.zig");
const clock = @import("runtime/clock.zig");

const Blinker = @import("drivers/Blinker.zig");
const Alert = @import("drivers/Alert.zig");
const Indicator = @import("drivers/Indicator.zig");
const STSpin = @import("drivers/STSpin.zig");
const stepper = @import("app/stepper.zig");
const StepperController = stepper.StepperController;
const Smoother = @import("app/smoother.zig").Smoother;

pub const microzig_options: microzig.Options = .{
    .log_level = .debug,
    .logFn = hal.uart.log,
};

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    std.log.err("panic: {s}", .{message});
    @breakpoint();
    while (true) {}
}

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

fn PidController(comptime T: type) type {
    return struct {
        const Self = @This();

        Kp: T = 0,
        Ki: T = 0,
        Kd: T = 0,
        set_point: T = 0,
        prev_err: T = 0,
        integral: T = 0,

        pub fn set(self: *Self, value: T) void {
            self.set_point = value;
        }

        pub fn update(self: *Self, current: T) T {
            const err = self.set_point - current;
            defer self.prev_err = err;
            self.integral += err;
            return self.Kp * err +
                self.Ki * self.integral +
                self.Kd * (err - self.prev_err);
        }
    };
}

const AnalogueInput = struct {
    const Self = @This();
    controller: *StepperController,
    value: ?u12 = null,
    smoother: Smoother(u12, 50) = .{},

    fn poll(ctx: *anyopaque, slot: *sched.ScheduleSlot) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (hal.adc.is_ready()) {
            const value = self.smoother.update(try hal.adc.read_result());
            if (self.value == null or (value ^ self.value.?) > 1) {
                self.value = value;
                self.controller.set(value);
                // std.log.info("input: {d:>5}", .{self.value.?});
            }
            hal.adc.start(.one_shot);
        }

        slot.delay(100);
    }

    pub fn start(self: *Self, slot: *sched.ScheduleSlot) void {
        slot.schedule(slot.now, poll, self);
        hal.adc.start(.one_shot);
    }
};

pub fn main() !void {
    @setEvalBranchQuota(std.math.maxInt(usize));
    logging.init(.{});
    std.log.debug("init", .{});
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
        .max_delta = 30,
        .rate = 80000,
    });
    controller.attach();

    const MICROSTEP = 8;

    blue1.activate();

    // Init ADC
    hal.adc.apply(.{});
    hal.adc.Input.configure_gpio_pin(.ain2);
    hal.adc.select_input(.ain2);
    var pot: AnalogueInput = .{ .controller = &controller };
    pot.start(scheduler.pri(3));

    motor.setMicrostep(MICROSTEP);
    try motor.start(scheduler.pri(0));

    var monitor: SchedulerMonitor = .{
        .indicator = busy,
    };

    const hook = monitor.hook();
    std.log.debug("running", .{});
    while (true) {
        _ = try scheduler.pollWithHook(clock.microsecondsSinceBoot(), hook);
    }
}
