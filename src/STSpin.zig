const std = @import("std");
const assert = std.debug.assert;

const microzig = if (@import("builtin").is_test)
    @import("testing/microzig.zig")
else
    @import("microzig");

const hal = microzig.hal;

const ScheduleSlot = @import("scheduler.zig").ScheduleSlot;
const events = @import("events.zig");

const Self = @This();

// During idling we wake up every 100µS to notice whether
// we need to do anything
pub const IDLE_TIME = 100; // µS

// We assert STEP for up to 2µS. If we used 1µS we might
// sometimes get a much shorter delay due to scheduler
// granularity. We only actually need 100ns
pub const STEP_TIME = 2; // µS
pub const MODE_HOLD_TIME = 100; // µS

pub const Config = struct {
    step_pin: *hal.gpio.Pin,
    dir_pin: *hal.gpio.Pin,
    steps_per_revolution: u16 = 200,
    mode1_pin: ?*hal.gpio.Pin = null,
    mode2_pin: ?*hal.gpio.Pin = null,
    en_fault_pin: ?*hal.gpio.Pin = null,
    reset_pin: ?*hal.gpio.Pin = null,
};

pub const State = enum(u8) {
    INIT,
    IDLE,
    STOPPING,
    STEP,
    STEPPED,
    MOVING,
    MODE_SETUP,
    MODE_HOLD,
};

pub const EventPayload = struct {
    target: *Self,
    state: State,
};

pub const Direction = enum(u2) {
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

direction: Direction = .UNKNOWN,

/// Current speed in hundredths of an RPM
speed_rpm100: u32 = 0,

/// Number of steps still to perform
steps_remaining: i32 = 0,

/// Current per-step interval
us_per_step: u32 = 0,

/// Event emitter - gets notifications of significant state changes:
///   .INIT <=> .IDLE
///   .IDLE <=> .MOVING
ee: events.Emitter(EventPayload, 5) = .empty,

/// Realtime event emitter - called after every step before the delay
/// to the next step is calculated. Event handlers can usefully vary
/// the speed here. Only allows two subscribers because it makes no
/// sense to have multiple parties fighting over control of the
/// speed. Having two allows a handler to be hooked with `once` and
/// be able to re-hook using `once` again from within the handler.
rt_ee: events.Emitter(*Self, 2) = .empty,

pub fn start(self: *Self, slot: *ScheduleSlot) void {
    assert(self.state == .INIT);
    self.adviseState(.IDLE);

    const pins = .{
        self.config.mode1_pin,
        self.config.mode2_pin,
        self.config.reset_pin,
    };

    inline for (pins) |maybe_pin| {
        if (maybe_pin) |pin| {
            pin.put(1);
        }
    }

    slot.schedule(slot.now, stateMachine, self);
}

pub fn stop(self: *Self) void {
    if (self.state != .INIT) {
        self.state = .STOPPING;
        self.speed_rpm100 = 0;
        self.steps_remaining = 0;
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
        self.us_per_step = @max(STEP_TIME, (1_000_000 * 60 * 100 / 2) / (spm100 / 2));
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

fn bitSet(bits: u4, pos: u2) u1 {
    return if ((bits & (@as(u4, 1) << pos)) != 0) 1 else 0;
}

fn stateMachine(ctx: *anyopaque, slot: *ScheduleSlot) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    sm: switch (self.state) {
        .INIT => unreachable,
        .IDLE => {
            if (self.microstep.pending != self.microstep.active) {
                self.state = .MODE_SETUP;
                continue :sm self.state;
            }

            if (self.steps_remaining != 0) {
                self.adviseState(.MOVING);
                continue :sm self.state;
            }

            slot.delay(IDLE_TIME);
        },

        .MOVING => {
            if (self.steps_remaining == 0) {
                self.adviseState(.IDLE);
                continue :sm self.state;
            }

            self.state = .STEP;

            const new_direction: Direction = if (self.steps_remaining < 0) .CCW else .CW;
            if (new_direction == self.direction)
                continue :sm self.state; // all set, go and step

            self.direction = new_direction;

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
                // Emit a real-time event so that setSpeed can be called
                // to get us moving again.
                self.rt_ee.emit(self);
                // Loop while we wait for non-zero speed
                slot.delay(IDLE_TIME);
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

            const delta: i32 = if (self.steps_remaining < 0) 1 else -1;
            self.steps_remaining += delta;

            if (self.steps_remaining == 0) {
                self.adviseState(.IDLE);
                continue :sm self.state;
            }

            // Emit a real-time event so that setSpeed can be called
            // before we delay.
            self.rt_ee.emit(self);

            self.state = .MOVING;
            slot.delay(self.us_per_step - STEP_TIME);
        },
        .MODE_SETUP => {
            const pending = self.microstep.pending;
            assert(pending != self.microstep.active);
            if (pending == 1 or pending == self.microstep.current) {
                // just diddle the mode bits and wait a bit
                const bit: u1 = if (pending == 1) 0 else 1;
                self.config.mode1_pin.?.put(bit);
                self.config.mode2_pin.?.put(bit);

                self.microstep.active = pending;

                self.state = .IDLE; // don't advise
            } else {
                // need to change mode
                // set reset low
                // set mode bits
                // wait 1µS
                // go to .MODE_HOLD
                self.config.reset_pin.?.put(0);
                const bits = lookupMicrostep(pending);
                self.config.mode1_pin.?.put(bitSet(bits, 0));
                self.config.mode2_pin.?.put(bitSet(bits, 1));
                self.config.step_pin.put(bitSet(bits, 2));
                self.config.dir_pin.put(bitSet(bits, 3));

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
        .STOPPING => {
            if (self.config.reset_pin) |reset_pin| {
                reset_pin.put(0);
            }
            self.adviseState(.INIT);
            // don't reschedule
        },
    }
}

const STSpin = Self;
const Pin = hal.gpio.Pin;
const Absolute = microzig.drivers.time.Absolute;
const expectEqual = std.testing.expectEqual;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const MotorRunner = struct {
    const MotorEvent = struct {
        timestamp: Absolute,
        payload: union(enum) {
            pin: struct { name: []const u8, state: u1 },
            state: EventPayload,
        },

        pub fn format(self: MotorEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("[{d:>6}] ", .{self.timestamp.to_us()});
            switch (self.payload) {
                .pin => |p| try writer.print("  pin {s} = {d}", .{ p.name, p.state }),
                .state => |s| try writer.print("state {s}", .{@tagName(s.state)}),
            }
        }
    };

    allocator: Allocator,
    timestamp: Absolute = .from_us(0),
    slot: ScheduleSlot = .{},
    emitter: Pin.Emitter = .empty,
    pins: std.ArrayList([]const u8) = .empty,
    log: std.ArrayList(MotorEvent) = .empty,
    state: State = .INIT,

    pub fn init(allocator: Allocator) MotorRunner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MotorRunner) void {
        for (self.pins.items) |name| {
            self.allocator.free(name);
        }
        self.pins.deinit(self.allocator);
        self.log.deinit(self.allocator);
    }

    pub fn advance(self: *MotorRunner) void {
        self.timestamp = self.slot.deadline;
        _ = self.slot.poll(self.timestamp);
        const stepper: *STSpin = @ptrCast(@alignCast(self.slot.context));
        self.state = stepper.state;
    }

    pub fn advanceToState(self: *MotorRunner, state: State, max_steps: u32) void {
        var avail_steps = max_steps;

        while (avail_steps > 0 and self.state == state) : (avail_steps -= 1)
            self.advance();

        while (avail_steps > 0 and self.state != state) : (avail_steps -= 1)
            self.advance();

        assert(avail_steps > 0);
    }

    pub fn pin(self: *MotorRunner, name: []const u8) Pin {
        const id: u8 = @intCast(self.pins.items.len);
        const dupe = self.allocator.dupe(u8, name) catch unreachable;
        self.pins.append(self.allocator, dupe) catch unreachable;
        return .{ .emitter = &self.emitter, .id = id };
    }

    pub fn attach(self: *MotorRunner, stepper: *STSpin) void {
        stepper.ee.addListener(onStateChange, self);
        self.emitter.addListener(onPinChange, self);
    }

    pub fn clearLog(self: *MotorRunner) void {
        self.log.items.len = 0;
    }

    fn logEvent(self: *MotorRunner, event: MotorEvent) void {
        self.log.append(self.allocator, event) catch unreachable;
    }

    fn onPinChange(ctx: *anyopaque, e: Pin.Event) void {
        const self: *MotorRunner = @ptrCast(@alignCast(ctx));
        self.logEvent(.{ .timestamp = self.timestamp, .payload = .{ .pin = .{
            .name = self.pins.items[e.target.id],
            .state = e.state,
        } } });
    }

    fn onStateChange(ctx: *anyopaque, e: EventPayload) void {
        const self: *MotorRunner = @ptrCast(@alignCast(ctx));
        self.logEvent(.{ .timestamp = self.timestamp, .payload = .{ .state = e } });
    }
};

test STSpin {
    var runner: MotorRunner = .init(std.testing.allocator);
    defer runner.deinit();

    var step_pin = runner.pin("STEP");
    var dir_pin = runner.pin("DIR");
    var reset_pin = runner.pin("RESET");
    var en_fault_pin = runner.pin("FAULT");
    var mode1_pin = runner.pin("MODE1");
    var mode2_pin = runner.pin("MODE2");

    var stepper: STSpin = .{ .config = .{
        .step_pin = &step_pin,
        .dir_pin = &dir_pin,
        .reset_pin = &reset_pin,
        .en_fault_pin = &en_fault_pin,
        .mode1_pin = &mode1_pin,
        .mode2_pin = &mode2_pin,
    } };

    runner.attach(&stepper);
    try expectEqual(.INIT, stepper.state);

    stepper.start(&runner.slot);
    runner.advance();

    try expectEqual(.IDLE, stepper.state);
    runner.advance();
    try expectEqual(.IDLE, stepper.state);

    stepper.setSpeed(6000); // 60rpm
    // print("µS/step = {d}\n", .{stepper.us_per_step});
    // stepper.setMicrostep(8);
    stepper.rotate(2);

    runner.advanceToState(.IDLE, 100);

    stepper.rotate(-4);

    runner.advanceToState(.IDLE, 100);

    stepper.stop();

    runner.advanceToState(.INIT, 100);

    // print("{any}\n", .{runner.slot});
    // print("{d}\n", .{stepper.steps_remaining});

    for (runner.log.items) |item| {
        print("{f}\n", .{item});
    }

    stepper.rotate(100);
}
