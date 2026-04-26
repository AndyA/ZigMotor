const std = @import("std");
const Io = std.Io;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const microzig = @import("testing/microzig.zig");
const Absolute = microzig.drivers.time.Absolute;

const STSpin = @import("drivers/STSpin.zig");
const stepper = @import("app/stepper.zig");

pub const USE_TEST_MICROZIG = true;

pub fn main(init: std.process.Init) !void {
    var runner: STSpin.TestMotorRunner = .init(init.gpa);
    defer runner.deinit();

    var motor: STSpin = .init(.{
        .step_pin = try runner.pin("STEP"),
        .dir_pin = try runner.pin("DIR"),
        .reset_pin = try runner.pin("RESET"),
        .en_fault_pin = try runner.pin("FAULT"),
        .mode1_pin = try runner.pin("MODE1"),
        .mode2_pin = try runner.pin("MODE2"),
    });

    var controller = stepper.StepperController.init(.{
        .motor = &motor,
        .min_rpm = 60,
        .max_rpm = 2400,
        .max_accel = 500000,
        .max_decel = 500000,
    });
    controller.attach();

    runner.attach(&motor);

    try motor.start(&runner.slot);
    try runner.advance();

    controller.set(3200);

    while (controller.state == .STOPPED)
        try runner.advance();

    while (controller.state == .MOVING) {
        try runner.advance();
        // runner.printLog();
        print("time: {d}, controller: {s}, speed: {d}/{d}, µS/step: {d} " ++
            "position: {d}, direction: {s}\n", .{
            runner.slot.now.to_us(),
            @tagName(controller.state),
            motor.speed,
            motor.getActualSpeed(),
            motor.us_per_step,
            motor.current_position,
            @tagName(motor.direction),
        });
        // if (motor.current_position > 6400)
        //     break;
    }
}
