const std = @import("std");
const Io = std.Io;
const print = std.debug.print;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const microzig = @import("testing/microzig.zig");
const Absolute = microzig.drivers.time.Absolute;

const STSpin = @import("drivers/STSpin.zig");
const stepper = @import("app/stepper.zig");

pub const USE_TEST_MICROZIG = true;

fn speedRamp(init: std.process.Init) !void {
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

const STEPS_PER_REVOLUTION = 200 * 4;
const STEP_TIME = 2;

fn recalculateSpeedFloat(rpm: f32) u32 {
    assert(rpm >= 0);

    if (rpm == 0)
        return 0;

    @setFloatMode(.optimized);
    const spm = STEPS_PER_REVOLUTION * rpm;
    return @intFromFloat(@max(@as(f32, STEP_TIME), @round(1_000_000 * 60 / spm)));
}

fn recalculateSpeedInt(rpm: u32) u32 {
    if (rpm == 0)
        return 0;

    const SCALE = 2;

    return ((1_000_000 * 60 * 100 / SCALE) /
        (rpm * STEPS_PER_REVOLUTION)) * SCALE;
}

fn intSpeed() void {
    var rpm: f32 = 0.01;
    while (rpm < 65536) {
        const f_step = recalculateSpeedFloat(rpm);
        const i_rpm: u32 = @intFromFloat(rpm * 100);
        const i_step = recalculateSpeedInt(i_rpm);
        print(
            "rpm: {d:>10.2}, i_rpm: {d:>8}, float: {d:>8}, int: {d:>8}\n",
            .{ rpm, i_rpm, f_step, i_step },
        );
        rpm *= 2;
    }
}

pub fn main(init: std.process.Init) !void {
    if (false)
        try speedRamp(init);
    if (true)
        intSpeed();
}
