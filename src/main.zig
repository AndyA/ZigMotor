const std = @import("std");

const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const GPIO_Device = rp2xxx.drivers.GPIO_Device;

const amn = @import("amnesiac.zig");

// Compile-time pin configuration
const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO14 = .{ .name = "led1", .direction = .out },
    .GPIO15 = .{ .name = "led2", .direction = .out },
    .GPIO16 = .{ .name = "led3", .direction = .out },
    .GPIO17 = .{ .name = "led4", .direction = .out },
    .GPIO25 = .{ .name = "led", .direction = .out },
};

const Blinker = struct {
    const Self = @This();

    pin: rp2xxx.gpio.Pin,
    delay: microzig.drivers.time.Duration,
    slot: u8,

    pub fn init_us(pin: rp2xxx.gpio.Pin, delay_us: u64, slot: u8) Self {
        return Self{
            .pin = pin,
            .delay = microzig.drivers.time.Duration.from_us(delay_us),
            .slot = slot,
        };
    }

    pub fn schedule(self: *Blinker, amnesiac: *Scheduler) void {
        const deadline = amnesiac.now.add_duration(self.delay);
        amnesiac.schedule(self.slot, deadline, step, self);
    }

    pub fn step(ctx: *anyopaque, amnesiac: *Scheduler) void {
        const self: *Blinker = @ptrCast(@alignCast(ctx));
        self.pin.toggle();
        self.schedule(amnesiac);
    }
};

const Scheduler = amn.Amnesiac(5);

pub fn main() !void {
    const pins = pin_config.apply();
    var scheduler = Scheduler{};

    var blinker = Blinker.init_us(pins.led, 250_000, 0);
    blinker.schedule(&scheduler);
    var led1 = Blinker.init_us(pins.led1, 125_000, 1);
    led1.schedule(&scheduler);
    var led2 = Blinker.init_us(pins.led2, 126_000, 2);
    led2.schedule(&scheduler);
    var led3 = Blinker.init_us(pins.led3, 127_000, 3);
    led3.schedule(&scheduler);
    var led4 = Blinker.init_us(pins.led4, 128_000, 4);
    led4.schedule(&scheduler);

    while (true) {
        _ = scheduler.pump(time.get_time_since_boot());
    }
}

test {
    _ = @import("stepper.zig");
    _ = @import("amnesiac.zig");
}
