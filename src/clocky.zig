const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const time = microzig.drivers.time;
const GPIO_Device = hal.drivers.GPIO_Device;
const Digital_IO = microzig.drivers.base.Digital_IO;
const clock = @import("runtime/clock.zig");

fn bitState(v: u64, bit: u6) Digital_IO.State {
    return if ((v & @as(u64, 1) << bit) != 0) .high else .low;
}

pub fn main() !void {
    var devices: [4]GPIO_Device = undefined;

    inline for (&devices, .{ 15, 14, 13, 12 }) |*dev, num| {
        const pin = hal.gpio.num(num);
        pin.set_function(.sio);
        dev.* = GPIO_Device.init(pin);
    }

    var dios: [4]Digital_IO = undefined;
    for (&devices, 0..) |*dev, i| {
        dios[i] = dev.digital_io();
        try dios[i].set_direction(.output);
    }

    while (true) {
        const now: u64 = clock.microsecondsSinceBoot().to_us() / 1_000_000;
        inline for (dios, 0..) |dio, bit| {
            try dio.write(bitState(now, @intCast(bit)));
        }
    }
}
