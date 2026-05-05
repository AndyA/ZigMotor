const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const Pin = hal.gpio.Pin;
const time = microzig.drivers.time;
const clock = @import("runtime/clock.zig");

fn bitState(v: u64, bit: u6) u1 {
    return if ((v & @as(u64, 1) << bit) != 0) 1 else 0;
}

// Compile-time pin configuration
const pin_config = hal.pins.GlobalConfiguration{
    .GPIO12 = .{ .name = "bit3", .direction = .out },
    .GPIO13 = .{ .name = "bit2", .direction = .out },
    .GPIO14 = .{ .name = "bit1", .direction = .out },
    .GPIO15 = .{ .name = "bit0", .direction = .out },
};

pub fn main() !void {
    const pins = pin_config.apply();

    const digits = [_]Pin{ pins.bit0, pins.bit1, pins.bit2, pins.bit3 };

    while (true) {
        const now: u64 = hal.time.get_time_since_boot().to_us() / 1_000_000;
        inline for (digits, 0..) |dio, bit| {
            dio.put(bitState(now, @intCast(bit)));
        }
    }
}
