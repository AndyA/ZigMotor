const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;

// Compile-time pin configuration
const pin_config = hal.pins.GlobalConfiguration{
    .GPIO20 = .{
        .name = "led",
        .direction = .out,
    },
};

pub fn main() !void {
    const pins = pin_config.apply();

    while (true) {
        pins.led.toggle();
    }
}
