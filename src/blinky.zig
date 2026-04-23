const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const time = microzig.drivers.time;

const sched = @import("runtime/scheduler.zig");
const clock = @import("runtime/clock.zig");
const events = @import("runtime/events.zig");
const Blinker = @import("drivers/Blinker.zig");

const Scheduler = sched.makeScheduler(5);

// Compile-time pin configuration
const pin_config = hal.pins.GlobalConfiguration{
    .GPIO12 = .{ .name = "led1", .direction = .out },
    .GPIO13 = .{ .name = "led2", .direction = .out },
    .GPIO14 = .{ .name = "led3", .direction = .out },
    .GPIO15 = .{ .name = "led4", .direction = .out },

    .GPIO25 = .{ .name = "led", .direction = .out },
};

pub fn main() !void {
    var scheduler: Scheduler = .empty;
    const pins = pin_config.apply();

    var led = Blinker.init_us(pins.led, 329_134);
    led.schedule(scheduler.pri(0));
    var led1 = Blinker.init_us(pins.led1, 125_000);
    led1.schedule(scheduler.pri(1));
    var led2 = Blinker.init_us(pins.led2, 125_010);
    led2.schedule(scheduler.pri(2));
    var led3 = Blinker.init_us(pins.led3, 125_030);
    led3.schedule(scheduler.pri(3));
    var led4 = Blinker.init_us(pins.led4, 125_050);
    led4.schedule(scheduler.pri(4));

    while (true) {
        _ = try scheduler.poll(clock.microsecondsSinceBoot());
    }
}
