const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;

const microzig = @import("../tools/bootstrap.zig").microzig;

const hal = microzig.hal;
const time = microzig.drivers.time;

const Pin = hal.gpio.Pin;

const ScheduleSlot = @import("../runtime/scheduler.zig").ScheduleSlot;
const events = @import("../runtime/events.zig");
const clock = @import("../runtime/clock.zig");

const Self = @This();

// During idling we wake up every 100µS to notice whether
// we need to do anything
pub const IDLE_TIME = 100; // µS

// We assert STEP for up to two ticks. If we used one tick we might
// sometimes get a much shorter delay due to scheduler granularity.
// We only actually need 100ns
pub const STEP_TIME = 2; // µS
pub const MODE_HOLD_TIME = 101; // µS

pub const Config = struct {
    steps_per_revolution: u16 = 200,
    step_pin: Pin,
    dir_pin: Pin,
    mode1_pin: ?Pin = null,
    mode2_pin: ?Pin = null,
    en_fault_pin: ?Pin = null,
    reset_pin: ?Pin = null,
    debug_pin: ?Pin = null,
};

pub const State = enum(u8) {
    INIT,
    IDLE,

    START,
    MOVING,
    STEP,
    STEPPING,
    STEPPED,

    MODE_SETUP,
    MODE_HOLD,
    MODE_DONE,

    STOPPING,
};

pub const EventPayload = struct {
    target: *Self,
    state: State,
};

pub const RTEventPayload = struct {
    target: *Self,
    state: State,
    now: time.Absolute,
};

pub const Direction = enum(u2) {
    CW,
    CCW,
    UNKNOWN, // at startup

    pub fn step(self: Direction) i8 {
        return switch (self) {
            .CW => 1,
            .CCW => -1,
            .UNKNOWN => 0,
        };
    }
};

config: Config,

state: State = .INIT,

microstep: struct {
    active: u16 = 0, // what the state machine observes
    pending: u16 = 16, // desired; switch at next idle
    current: u16 = 0, // current hardware setting when no full-step override

    pub fn activeOrPending(self: @This()) u16 {
        if (self.active != 0)
            return self.active;
        assert(self.pending != 0);
        return self.pending;
    }

    pub fn commit(self: *@This()) void {
        self.active = self.pending;
        self.current = self.pending;
    }

    pub fn dirty(self: @This()) bool {
        return self.active != self.pending;
    }
} = .{},

direction: Direction = .UNKNOWN,

/// Current speed in RPM*100
speed: u32 = 0,

/// Number of steps still to perform
steps_remaining: i32 = 0,

/// The current position of the motor
current_position: i64 = 0,

/// Current per-step interval
us_per_step: u32 = 0,

/// Current microstep phase
phase: u8 = 0,

/// Event emitter - gets notifications of significant state changes:
///   .INIT <=> .IDLE
///   .IDLE <=> .MOVING
state_ee: events.Emitter(EventPayload, 5) = .empty,

/// Realtime event emitter - called after every step before the delay
/// to the next step is calculated. Event handlers can usefully vary
/// the speed here. Only allows two subscribers because it makes no
/// sense to have multiple parties fighting over control of the
/// speed. Having two allows a handler to be hooked with `once` and
/// be able to re-hook using `once` again from within the handler.
rt_ee: events.Emitter(RTEventPayload, 2) = .empty,

pub fn init(config: Config) Self {
    return .{ .config = config };
}

pub fn start(self: *Self, slot: *ScheduleSlot) !void {
    assert(self.state == .INIT);
    self.direction = .UNKNOWN;

    self.config.dir_pin.put(1);
    self.config.step_pin.put(1);

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

    if (self.canSetMicrostep()) {
        // Force state machine to configure microstep
        self.microstep.active = 0;
        self.microstep.current = 0;
    }

    self.config.dir_pin.put(0);
    self.config.step_pin.put(0);

    slot.schedule(slot.now, stateMachine, self);
    try self.notifyState(.IDLE);
}

pub fn canSetMicrostep(self: Self) bool {
    return self.config.mode1_pin != null and
        self.config.mode2_pin != null and
        self.config.reset_pin != null;
}

pub fn stop(self: *Self) void {
    if (self.state != .INIT) {
        self.state = .STOPPING;
        self.setSpeedFloat(0);
        self.steps_remaining = 0;
        self.phase = 0;
    }
}

pub fn rotate(self: *Self, steps: i32) void {
    self.steps_remaining +|= steps;
}

pub fn setRemaining(self: *Self, steps: i32) void {
    self.steps_remaining = steps;
}

pub fn stepsPerRevolution(self: Self) u32 {
    return self.config.steps_per_revolution *
        self.microstep.activeOrPending();
}

fn calculateSpeed(self: *Self, rpm: u32) u32 {
    if (rpm == 0)
        return 0;

    const SCALE = 2;
    return ((1_000_000 * 60 * 100 / SCALE) /
        (rpm * self.stepsPerRevolution())) * SCALE;
}

fn recalculateSpeed(self: *Self) void {
    self.us_per_step = @max(STEP_TIME * 2, self.calculateSpeed(self.speed));
}

pub fn setSpeed(self: *Self, rpm: u32) void {
    if (rpm != self.speed) {
        self.speed = rpm;
        self.recalculateSpeed();
    }
}

// Set the speed in RPM
pub fn setSpeedFloat(self: *Self, rpm: f32) void {
    self.setSpeed(@intFromFloat(rpm * 100));
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
//  1  0  0  0 Full-step - 1/32nd step
//  0  1  0  0 Full-step - 1/128nd step
//  1  1  0  0 Full-step - 1/256th step

fn lookupMicrostep(microstep: u16) u4 {
    return switch (microstep) {
        1 => 0b0000, // also 0b1000, 0b0100, 0b1100
        2 => 0b0101,
        4 => 0b1010,
        8 => 0b0111, // also 0b1101
        16 => 0b1111,
        32 => 0b0010,
        64 => 0b1011, // also 0b1110
        128 => 0b0001,
        256 => 0b0011, // also 0b1001, 0b0110
        else => unreachable,
    };
}

fn notifyState(self: *Self, state: State) !void {
    self.state = state;
    try self.state_ee.emit(.{ .target = self, .state = state });
}

fn debugFlag(self: Self, state: u1) void {
    if (self.config.debug_pin) |debug|
        debug.put(state);
}

fn rtNotify(self: *Self, now: time.Absolute) !void {
    self.debugFlag(1);
    defer self.debugFlag(0);

    try self.rt_ee.emit(.{
        .target = self,
        .state = self.state,
        .now = now,
    });
}

fn bitSet(bits: u4, pos: u2) u1 {
    return if ((bits & (@as(u4, 1) << pos)) != 0) 1 else 0;
}

fn stateMachine(ctx: *anyopaque, slot: *ScheduleSlot) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    sm: switch (self.state) {
        .INIT => unreachable,
        .IDLE => {
            if (self.microstep.dirty()) {
                self.state = .MODE_SETUP;
                continue :sm self.state;
            }

            // Keep the RT notifications coming
            try self.rtNotify(slot.now);

            if (self.steps_remaining != 0) {
                try self.notifyState(.START);
                continue :sm self.state;
            }

            slot.delay(IDLE_TIME);
        },

        .START => {
            self.direction = .UNKNOWN;
            self.state = .MOVING;
            continue :sm self.state;
        },
        .MOVING => {
            // RT notify so speed, direction can be set before step starts
            try self.rtNotify(slot.now);

            if (self.steps_remaining == 0) {
                try self.notifyState(.IDLE);
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
                try self.notifyState(.IDLE);
                continue :sm self.state;
            }

            if (self.speed == 0) {
                // Loop while we wait for non-zero speed
                self.state = .MOVING;
                slot.delay(IDLE_TIME);
            } else {
                self.config.step_pin.put(1);
                self.state = .STEPPING;
                slot.delay(STEP_TIME);
            }
        },
        .STEPPING => {
            self.config.step_pin.put(0);

            self.state = .STEPPED;
            slot.delay(self.us_per_step - STEP_TIME);
        },
        .STEPPED => {
            const delta: i32 = if (self.steps_remaining > 0) 1 else -1;
            self.steps_remaining -= delta;
            self.current_position += delta;

            // Track microstep phase in 1/256th of a step
            const step_size: u16 = @divTrunc(256, self.microstep.active);
            const phase_delta: i32 = delta * step_size;
            self.phase = @intCast((@as(i32, self.phase) + phase_delta) & 0xff);

            if (self.steps_remaining == 0)
                try self.notifyState(.IDLE)
            else
                self.state = .MOVING;

            continue :sm self.state;
        },

        .MODE_SETUP => {
            assert(self.microstep.dirty());
            const pending = self.microstep.pending;
            if (pending == 1 or pending == self.microstep.current) {
                // just diddle the mode bits and wait a bit
                if (pending == 1) {
                    self.config.mode1_pin.?.put(0);
                    self.config.mode2_pin.?.put(0);
                } else {
                    self.config.mode1_pin.?.put(1);
                    self.config.mode2_pin.?.put(1);
                }

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

                self.microstep.commit();
                self.state = .MODE_HOLD;
            }

            // Recalculate speed for the new microstep
            self.recalculateSpeed();
            slot.delay(STEP_TIME);
        },
        .MODE_HOLD => {
            // set reset high
            // wait 100µS
            // go to .MODE_DONE
            self.state = .MODE_DONE; // don't advise
            self.config.reset_pin.?.put(1);
            slot.delay(MODE_HOLD_TIME);
        },
        .MODE_DONE => {
            self.config.mode1_pin.?.put(1);
            self.config.mode2_pin.?.put(1);
            self.config.step_pin.put(0);
            self.config.dir_pin.put(0);
            self.state = .IDLE;
            slot.delay(STEP_TIME);
        },

        .STOPPING => {
            if (self.config.reset_pin) |reset_pin|
                reset_pin.put(0);
            try self.notifyState(.INIT);
            // don't reschedule
        },
    }
}

const expectEqual = std.testing.expectEqual;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Absolute = microzig.drivers.time.Absolute;

const STSpin = Self;

pub const TestMotorRunner = struct {
    pub const MotorEvent = struct {
        timestamp: Absolute,
        payload: union(enum) {
            pin: Pin.Event,
            state: EventPayload,
            rt_state: RTEventPayload,
        },

        pub fn format(self: MotorEvent, w: *Io.Writer) Io.Writer.Error!void {
            try w.print("[{d:>6}] ", .{self.timestamp.to_us()});
            switch (self.payload) {
                .pin => |p| switch (p.reason) {
                    .PUT => try w.print("  pin {s:<6} put {d}", .{ p.name, p.driver.state }),
                    .TOGGLE => try w.print("  pin {s:<6} toggle", .{p.name}),
                },
                .state => |s| try w.print("state {s}", .{@tagName(s.state)}),
                .rt_state => |s| try w.print("rt state {s}", .{@tagName(s.state)}),
            }
        }
    };

    allocator: Allocator,
    timestamp: Absolute = .from_us(0),
    slot: ScheduleSlot = .{ .now = .from_us(1_000_000) },

    pin_emitter: Pin.Emitter = .empty,
    pins: std.ArrayList(Pin) = .empty,

    log: std.ArrayList(MotorEvent) = .empty,
    state: State = .INIT,

    pub fn init(allocator: Allocator) TestMotorRunner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TestMotorRunner) void {
        for (self.pins.items) |p|
            p.deinit(self.allocator);
        self.pins.deinit(self.allocator);

        self.log.deinit(self.allocator);
    }

    pub fn advance(self: *TestMotorRunner) !void {
        self.timestamp = self.slot.deadline;
        _ = try self.slot.poll(self.timestamp);
        const stepper: *STSpin = @ptrCast(@alignCast(self.slot.context));
        self.state = stepper.state;
    }

    pub fn advanceToState(self: *TestMotorRunner, state: State, max_steps: u32) !void {
        var avail_steps = max_steps;

        while (avail_steps > 0 and self.state == state) : (avail_steps -= 1)
            try self.advance();

        while (avail_steps > 0 and self.state != state) : (avail_steps -= 1)
            try self.advance();

        assert(avail_steps > 0);
    }

    pub fn pin(self: *TestMotorRunner, name: []const u8) !Pin {
        const p = try Pin.init(self.allocator, name, &self.pin_emitter);
        try self.pins.append(self.allocator, p);
        return p;
    }

    pub fn attach(self: *TestMotorRunner, stepper: *STSpin) void {
        stepper.state_ee.addListener(onStateChange, self);
        stepper.rt_ee.addListener(onRTStateChange, self);
        self.pin_emitter.addListener(onPinChange, self);
    }

    pub fn clearLog(self: *TestMotorRunner) void {
        self.log.items.len = 0;
    }

    pub fn printLog(self: *TestMotorRunner) void {
        for (self.log.items) |item| {
            print("{f}\n", .{item});
            self.clearLog();
        }
    }

    fn logEvent(self: *TestMotorRunner, event: MotorEvent) !void {
        try self.log.append(self.allocator, event);
    }

    fn onPinChange(ctx: *anyopaque, e: Pin.Event) !void {
        const self: *TestMotorRunner = @ptrCast(@alignCast(ctx));
        try self.logEvent(.{ .timestamp = self.timestamp, .payload = .{ .pin = e } });
    }

    fn onStateChange(ctx: *anyopaque, e: EventPayload) !void {
        const self: *TestMotorRunner = @ptrCast(@alignCast(ctx));
        try self.logEvent(.{ .timestamp = self.timestamp, .payload = .{ .state = e } });
    }

    fn onRTStateChange(ctx: *anyopaque, e: RTEventPayload) !void {
        const self: *TestMotorRunner = @ptrCast(@alignCast(ctx));
        try self.logEvent(.{ .timestamp = self.timestamp, .payload = .{ .rt_state = e } });
    }
};

test STSpin {
    var runner: TestMotorRunner = .init(std.testing.allocator);
    defer runner.deinit();

    var stepper: STSpin = .init(.{
        .step_pin = try runner.pin("STEP"),
        .dir_pin = try runner.pin("DIR"),
        .reset_pin = try runner.pin("RESET"),
        .en_fault_pin = try runner.pin("FAULT"),
        .mode1_pin = try runner.pin("MODE1"),
        .mode2_pin = try runner.pin("MODE2"),
    });

    runner.attach(&stepper);
    try expectEqual(.INIT, stepper.state);

    try stepper.start(&runner.slot);
    // try runner.advance();

    // try expectEqual(.IDLE, stepper.state);
    // try runner.advance();
    // try expectEqual(.IDLE, stepper.state);

    stepper.setSpeedFloat(60);
    // print("µS/step = {d}\n", .{stepper.us_per_step});
    // stepper.setMicrostep(8);
    stepper.rotate(2);

    try runner.advanceToState(.IDLE, 100);

    // try expectEqual(32, stepper.phase);

    // try stepper.setMicrostep(8);

    stepper.rotate(-4);

    try runner.advanceToState(.IDLE, 100);
    // try runner.advanceToState(.IDLE, 100);

    // try expectEqual(224, stepper.phase);

    stepper.stop();

    try runner.advanceToState(.INIT, 100);

    // print("{any}\n", .{runner.slot});
    // print("{d}\n", .{stepper.steps_remaining});

    if (false)
        runner.printLog();

    stepper.rotate(100);
}
