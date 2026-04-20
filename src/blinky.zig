const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const time = microzig.drivers.time;
const GPIO_Device = hal.drivers.GPIO_Device;
const Digital_IO = microzig.drivers.base.Digital_IO;

const sched = @import("runtime/scheduler.zig");
const events = @import("runtime/events.zig");
const Blinker = @import("drivers/Blinker.zig");

const Scheduler = sched.makeScheduler(5);

pub fn main() !void {
    var scheduler: Scheduler = .empty;

    var pins: struct {
        led: GPIO_Device,
        led1: GPIO_Device,
        led2: GPIO_Device,
        led3: GPIO_Device,
        led4: GPIO_Device,
    } = undefined;

    inline for (std.meta.fields(@TypeOf(pins)), .{ 25, 14, 15, 16, 17 }) |field, num| {
        const pin = hal.gpio.num(num);
        pin.set_function(.sio);
        @field(pins, field.name) = GPIO_Device.init(pin);
    }

    var led = try Blinker.init_us(pins.led.digital_io(), 329_134);
    led.schedule(scheduler.pri(0));
    var led1 = try Blinker.init_us(pins.led1.digital_io(), 125_000);
    led1.schedule(scheduler.pri(1));
    var led2 = try Blinker.init_us(pins.led2.digital_io(), 125_010);
    led2.schedule(scheduler.pri(2));
    var led3 = try Blinker.init_us(pins.led3.digital_io(), 125_030);
    led3.schedule(scheduler.pri(3));
    var led4 = try Blinker.init_us(pins.led4.digital_io(), 125_050);
    led4.schedule(scheduler.pri(4));

    while (true) {
        _ = try scheduler.poll(hal.time.get_time_since_boot());
    }
}
