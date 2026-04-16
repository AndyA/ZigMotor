const std = @import("std");

const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const GPIO_Device = rp2xxx.drivers.GPIO_Device;

const amn = @import("amnesiac.zig");

// Compile-time pin configuration
const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO25 = .{
        .name = "led",
        .direction = .out,
    },
};

const Blinker = struct {
    pin: rp2xxx.gpio.Pin,
    delay_us: microzig.drivers.time.Duration,

    pub fn schedule(self: *Blinker, amnesiac: *Scheduler) void {
        const deadline = amnesiac.now.add_duration(self.delay_us);
        amnesiac.schedule(0, deadline, step, self);
    }

    pub fn step(ctx: *anyopaque, amnesiac: *Scheduler) void {
        const self: *Blinker = @ptrCast(@alignCast(ctx));
        self.pin.toggle();
        self.schedule(amnesiac);
    }
};

const Scheduler = amn.Amnesiac(2);

pub fn main() !void {
    const pins = pin_config.apply();
    var scheduler = Scheduler.init();

    var blinker = Blinker{
        .pin = pins.led,
        .delay_us = microzig.drivers.time.Duration.from_us(250_000),
    };
    blinker.schedule(&scheduler);

    while (true) {
        _ = scheduler.pump(time.get_time_since_boot());
    }
}

test {
    _ = @import("stepper.zig");
    _ = @import("amnesiac.zig");
}
