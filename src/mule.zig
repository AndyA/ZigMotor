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
        .min_rpm = 5,
        .max_rpm = 600,
        .max_delta = 5,
        .rate = 20000,
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
        print("t: {d:>7}, s: {s:>7}, rpm: {d:>5}, µS/s: {d:>4}, " ++
            "set: {d:>5}, sd: {d:>5}, pos: {d:>5}, dir: {s:>3}, rem: {d:>5}\n", .{
            runner.slot.now.to_us(),
            @tagName(controller.state),
            motor.speed,
            motor.us_per_step,
            controller.set_point,
            controller.stopping_distance,
            motor.current_position,
            @tagName(motor.direction),
            motor.steps_remaining,
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
    if (true)
        try speedRamp(init);
    if (false)
        intSpeed();
}

test {
    _ = @import("runtime/scheduler.zig");
    _ = @import("runtime/events.zig");
    _ = @import("runtime/ticker.zig");
    _ = @import("drivers/STSpin.zig");
    _ = @import("app/stepper.zig");
}
