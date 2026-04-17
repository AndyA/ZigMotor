const std = @import("std");

const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const GPIO_Device = rp2xxx.drivers.GPIO_Device;

const sched = @import("scheduler.zig");

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

    pub fn init_us(pin: rp2xxx.gpio.Pin, delay_us: u64) Self {
        return Self{
            .pin = pin,
            .delay = microzig.drivers.time.Duration.from_us(delay_us),
        };
    }

    pub fn schedule(self: *Blinker, slot: *sched.ScheduleSlot) void {
        const deadline = slot.then.add_duration(self.delay);
        slot.schedule(deadline, step, self);
    }

    pub fn step(ctx: *anyopaque, slot: *sched.ScheduleSlot) void {
        const self: *Blinker = @ptrCast(@alignCast(ctx));
        self.pin.toggle();
        self.schedule(slot);
    }
};

const Scheduler = sched.makeScheduler(5);

pub fn main() !void {
    const pins = pin_config.apply();
    var scheduler = Scheduler{};

    var blinker = Blinker.init_us(pins.led, 250_000);
    blinker.schedule(scheduler.pri(0));
    var led1 = Blinker.init_us(pins.led1, 125_000);
    led1.schedule(scheduler.pri(1));
    var led2 = Blinker.init_us(pins.led2, 126_000);
    led2.schedule(scheduler.pri(2));
    var led3 = Blinker.init_us(pins.led3, 127_000);
    led3.schedule(scheduler.pri(3));
    var led4 = Blinker.init_us(pins.led4, 128_000);
    led4.schedule(scheduler.pri(4));

    while (true) {
        _ = scheduler.poll(time.get_time_since_boot());
    }
}

test {
    _ = @import("scheduler.zig");
}
