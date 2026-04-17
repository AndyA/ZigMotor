const std = @import("std");
const assert = std.debug.assert;

const microzig = @import("microzig");
const hal = microzig.hal;
const time = microzig.drivers.time;

const ScheduleSlot = @import("scheduler.zig").ScheduleSlot;
const events = @import("events.zig");

const Self = @This();

pub const IDLE_POLL_RATE = 100; // µS

// We assert STEP for up to 2µS. If we used 1µS we might
// sometimes get a much shorter delay due to scheduler
// granularity. We only actually need 100ns
pub const STEP_TIME = 2; // µS
pub const MODE_HOLD_TIME = 100; // µS

pub const Config = struct {
    step_pin: hal.gpio.Pin,
    dir_pin: hal.gpio.Pin,
    steps_per_revolution: u16 = 200,
    mode1_pin: ?hal.gpio.Pin = null,
    mode2_pin: ?hal.gpio.Pin = null,
    en_fault_pin: ?hal.gpio.Pin = null,
    reset_pin: ?hal.gpio.Pin = null,
};

pub const Ramp = struct {};

pub const State = enum(u8) {
    INIT,
    IDLE,
    STOPPING,
    STEP,
    STEPPED,
    SET_DIRECTION,
    MODE_SETUP,
    MODE_HOLD,
};

pub const EventPayload = struct {
    target: *Self,
    state: State,
};

pub const Direction = enum(u1) {
    CW,
    CCW,
    UNKNOWN, // at startup
};

config: Config,

state: State = .INIT,

microstep: struct {
    active: u16 = 16, // what the state machine observes
    pending: u16 = 16, // desired; switch at next idle
    current: u16 = 16, // current hardware setting when no full-step override
} = .{},

// microstep: u16 = 16,
// full_step: bool = false, // step size == 1
direction: Direction = .UNKNOWN,

// Current speed in hundredths of an RPM
speed_rpm100: u32,

// Number of steps still to perform
steps_remaining: i32 = 0,
// Current per-step interval
us_per_step: u32 = 0,

ee: events.Emitter(EventPayload, 5) = .empty,

pub fn start(self: *Self, slot: *ScheduleSlot) void {
    assert(self.state == .INIT);
    self.adviseState(.IDLE);
    slot.schedule(slot.then, stateMachine, self);
}

pub fn stop(self: *Self) void {
    if (self.state != .IDLE) {
        self.state = .STOPPING;
    }
}

pub fn rotate(self: *Self, steps: i32) void {
    self.steps_remaining +|= steps;
}

pub fn stepsPerRevolution(self: Self) u32 {
    return self.config.steps_per_revolution * self.microstep.active;
}

// Set the speed in hundredths of an RPM
pub fn setSpeed(self: *Self, rpm100: u32) void {
    if (rpm100 != 0) {
        const spr = self.stepsPerRevolution();
        const max_rpm100 = std.math.maxInt(u32) / spr;
        const spm100 = @min(max_rpm100, rpm100) * spr;
        self.us_per_step = (1_000_000 * 60 * 100 / 2) / (spm100 / 2);
    }
    self.speed_rpm100 = rpm100;
}

pub fn setMicrostep(self: *Self, microstep: u16) void {
    _ = lookupMicrostep(microstep); // unreachable if bad
    self.microstep.pending = microstep;
}

// DR ST
// M4 M3 M2 M1
//  0  0  0  0 Full-step
//  0  1  0  1 1/2 step
//  1  0  1  0 1/4th step
//  0  1  1  1 1/8th step
//  1  1  0  1 1/8th step
//  1  1  1  1 1/16th step
//  0  0  1  0 1/32nd step
//  1  0  1  1 1/64th step
//  1  1  1  0 1/64th step
//  0  0  0  1 1/128th step
//  0  0  1  1 1/256th step
//  1  0  0  1 1/256th step
//  0  1  1  0 1/256th step
//  1  0  0  0 Full-step - 1/32nd step (1)
//  0  1  0  0 Full-step - 1/128nd step (1)
//  1  1  0  0 Full-step - 1/256th step (1)

fn lookupMicrostep(microstep: u16) u4 {
    const table = [_]struct { ms: u16, bits: u4 }{
        .{ .ms = 1, .bits = 0b0000 },
        .{ .ms = 2, .bits = 0b0101 },
        .{ .ms = 4, .bits = 0b1010 },
        .{ .ms = 8, .bits = 0b0111 },
        .{ .ms = 16, .bits = 0b1111 },
        .{ .ms = 32, .bits = 0b0010 },
        .{ .ms = 64, .bits = 0b1011 },
        .{ .ms = 128, .bits = 0b0001 },
        .{ .ms = 256, .bits = 0b0011 },
    };
    for (table) |ent| {
        if (ent.ms == microstep)
            return ent.bits;
    }
    unreachable;
}

fn adviseState(self: *Self, state: State) void {
    self.state = state;
    self.ee.emit(.{ .target = self, .state = state });
}

fn stateMachine(ctx: *anyopaque, slot: *ScheduleSlot) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    sm: switch (self.state) {
        .INIT => unreachable,
        .SET_DIRECTION => {
            if (self.steps_remaining == 0) {
                self.adviseState(.IDLE);
                continue :sm self.state;
            }

            self.state = .STEP;

            const new_direction: Direction = if (self.steps_remaining < 0) .CCW else .CW;
            if (new_direction == self.direction)
                continue :sm self.state; // all set, go and step

            self.config.dir_pin.put(switch (new_direction) {
                .CW => 1,
                .CCW => 0,
                else => unreachable,
            });
            slot.delay(STEP_TIME); // allow dir to settle
        },
        .STEP => {
            if (self.steps_remaining == 0) {
                self.adviseState(.IDLE);
                continue :sm self.state;
            }

            if (self.speed_rpm100 == 0) {
                // Loop while we wait for non-zero speed
                slot.delay(IDLE_POLL_RATE);
            } else {
                self.config.step_pin.put(1);
                self.state = .STEPPED;
                slot.delay(STEP_TIME);
            }
        },
        .STEPPED => {
            self.config.step_pin.put(0);

            if (self.steps_remaining == 0) {
                self.adviseState(.IDLE);
                continue :sm self.state;
            }

            const delta = if (self.steps_remaining < 0) 1 else -1;
            self.steps_remaining += delta;

            if (self.steps_remaining == 0) {
                self.adviseState(.IDLE);
                continue :sm self.state;
            }

            self.state = .SET_DIRECTION;
            slot.delay(self.us_per_step - STEP_TIME);
        },
        .MODE_SETUP => {
            const pending = self.microstep.pending;
            assert(pending != self.microstep.active);
            if (pending == 1 or pending == self.microstep.current) {
                // just diddle the mode bits and wait a bit
                const bit = if (pending == 1) 0 else 1;
                self.config.mode1_pin.?.put(bit);
                self.config.mode2_pin.?.put(bit);

                self.microstep.active = pending;

                self.state = .IDLE; // don't advise
            } else {
                // need to change mode
                // set reset low
                // set mode bits
                // wait 1µS
                self.config.reset_pin.?.put(0);
                const bits = lookupMicrostep(pending);
                self.config.mode1_pin.?.put(bitSet(bits, 0));
                self.config.mode2_pin.?.put(bitSet(bits, 1));
                self.config.step_pin.?.put(bitSet(bits, 2));
                self.config.dir_pin.?.put(bitSet(bits, 3));

                self.microstep.active = pending;
                self.microstep.current = pending;

                self.state = .MODE_HOLD;
            }

            // Recalculate speed for the new microstep
            self.setSpeed(self.speed_rpm100);

            slot.delay(STEP_TIME);
        },
        .MODE_HOLD => {
            // set reset high
            // wait 100µS
            // go to .IDLE
            self.state = .IDLE; // don't advise
            self.config.reset_pin.?.put(1);
            slot.delay(MODE_HOLD_TIME);
        },
        .IDLE => {
            if (self.microstep.pending != self.microstep.active) {
                self.state = .MODE_SETUP;
                continue :sm self.state;
            }

            if (self.steps_remaining != 0) {
                self.state = .SET_DIRECTION;
                continue :sm self.state;
            }

            slot.delay(IDLE_POLL_RATE);
        },
        .STOPPING => {
            self.adviseState(.INIT);
            // don't reschedule
        },
    }
}

fn bitSet(bits: u4, pos: u3) u1 {
    return if ((bits & (1 << pos)) != 0) 1 else 0;
}
