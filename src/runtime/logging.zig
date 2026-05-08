const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;

pub const microzig_options: microzig.Options = .{
    .log_level = .debug,
    .logFn = hal.uart.log,
};

pub const Config = struct {
    uart: u1 = 0,
    tx_pin: u9 = 0,
};

pub fn init(config: Config) void {
    const uart = hal.uart.instance.num(config.uart);
    const uart_tx_pin = hal.gpio.num(config.tx_pin);

    uart_tx_pin.set_function(.uart);
    uart.apply(.{ .clock_config = hal.clock_config });
    hal.uart.init_logger(uart, &.{});
}
