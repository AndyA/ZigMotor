const microzig = @import("microzig");
const hal = microzig.hal;
const time = microzig.drivers.time;

const sched = @import("scheduler.zig");
const events = @import("events.zig");

const STSpin = @import("STSpin.zig");

// Compile-time pin configuration
const pin_config = hal.pins.GlobalConfiguration{
    .GPIO14 = .{ .name = "led1", .direction = .out },
    .GPIO15 = .{ .name = "led2", .direction = .out },
    .GPIO16 = .{ .name = "led3", .direction = .out },
    .GPIO17 = .{ .name = "led4", .direction = .out },
    .GPIO25 = .{ .name = "led", .direction = .out },
};

const Blinker = struct {
    const Self = @This();

    pin: hal.gpio.Pin,
    delay: time.Duration,

    pub fn init_us(pin: hal.gpio.Pin, delay_us: u64) Self {
        return Self{
            .pin = pin,
            .delay = time.Duration.from_us(delay_us),
        };
    }

    pub fn schedule(self: *Self, slot: *sched.ScheduleSlot) void {
        const deadline = slot.now.add_duration(self.delay);
        slot.schedule(deadline, task, self);
    }

    fn task(ctx: *anyopaque, slot: *sched.ScheduleSlot) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.pin.toggle();
        self.schedule(slot);
    }
};

const Scheduler = sched.makeScheduler(5);

pub fn main() !void {
    const pins = pin_config.apply();
    var scheduler: Scheduler = .empty;

    var blinker = Blinker.init_us(pins.led, 329_134);
    blinker.schedule(scheduler.pri(0));
    var led1 = Blinker.init_us(pins.led1, 125_000);
    led1.schedule(scheduler.pri(1));
    var led2 = Blinker.init_us(pins.led2, 125_100);
    led2.schedule(scheduler.pri(2));
    var led3 = Blinker.init_us(pins.led3, 125_200);
    led3.schedule(scheduler.pri(3));
    var led4 = Blinker.init_us(pins.led4, 125_300);
    led4.schedule(scheduler.pri(4));

    while (true) {
        _ = scheduler.poll(hal.time.get_time_since_boot());
    }
}

test {
    _ = @import("scheduler.zig");
    _ = @import("events.zig");
    _ = @import("STSpin.zig");
}
