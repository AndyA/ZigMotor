const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    std.log.err("panic: {s}", .{message});
    @breakpoint();
    while (true) {}
}

pub const microzig_options: microzig.Options = .{
    .log_level = .debug,
    .logFn = hal.uart.log,
};

pub fn init() void {
    const uart = hal.uart.instance.num(0);
    const uart_tx_pin = hal.gpio.num(0);
    uart_tx_pin.set_function(.uart);
    uart.apply(.{ .clock_config = hal.clock_config });
    hal.uart.init_logger(uart, &.{});
}
