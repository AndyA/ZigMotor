const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;
const GPIO_Device = hal.drivers.GPIO_Device;

const sched = @import("scheduler.zig");
const events = @import("events.zig");

const STSpin = @import("STSpin.zig");
const Scheduler = sched.makeScheduler(5);

const Sequencer = struct {
    const Self = @This();

    pub const Step = struct {
        speed: u32 = 1500, // 100ths of RPM
        steps: i32,
    };
    const MaxSteps = 100;

    steps: [MaxSteps]Step = undefined,
    used: u16 = 0,
    current: u16 = 0,

    pub const empty: Self = .{};

    pub fn attach(self: *Self, stepper: *STSpin) void {
        stepper.ee.addListener(onStateChange, self);
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

pub fn main() !void {
    var scheduler: Scheduler = .empty;

    var pins: struct {
        step: GPIO_Device,
        dir: GPIO_Device,
        mode1: GPIO_Device,
        mode2: GPIO_Device,
        fault: GPIO_Device,
        reset: GPIO_Device,
    } = undefined;

    inline for (std.meta.fields(@TypeOf(pins)), .{ 20, 21, 19, 18, 17, 16 }) |field, num| {
        const pin = hal.gpio.num(num);
        pin.set_function(.sio);
        @field(pins, field.name) = GPIO_Device.init(pin);
    }

    var stepper: STSpin = .init(.{
        .step_pin = pins.step.digital_io(),
        .dir_pin = pins.dir.digital_io(),
        .reset_pin = pins.reset.digital_io(),
        .en_fault_pin = pins.fault.digital_io(),
        .mode1_pin = pins.mode1.digital_io(),
        .mode2_pin = pins.mode2.digital_io(),
    });

    const steps = &[_]Sequencer.Step{
        .{ .speed = 1500, .steps = 50 * 16 },
        .{ .speed = 500, .steps = -100 * 16 },
        .{ .speed = 1000, .steps = 50 * 16 },
    };

    var sequencer: Sequencer = .empty;
    sequencer.addSteps(steps);
    sequencer.attach(&stepper);

    try stepper.start(scheduler.pri(0));

    while (true) {
        _ = try scheduler.poll(hal.time.get_time_since_boot());
    }
}

test {
    _ = @import("scheduler.zig");
    _ = @import("events.zig");
    _ = @import("STSpin.zig");
}
