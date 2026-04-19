const events = @import("../events.zig");

pub const hal = struct {
    pub const gpio = struct {
        pub const Pin = struct {
            pub const Event = struct {
                target: *Pin,
                state: u1,
            };
            pub const Emitter = events.Emitter(Event, 2);

            emitter: *Emitter,
            id: u8,
            state: u1 = 0,

            pub fn put(self: *Pin, state: u1) void {
                self.state = state;
                self.emitter.emit(.{ .target = self, .state = state });
            }
        };
    };
};

pub const drivers = struct {
    pub const time = struct {
        // Lifted from microzig source
        pub const Absolute = enum(u64) {
            _,

            pub fn from_us(us: u64) Absolute {
                return @as(Absolute, @enumFromInt(us));
            }

            pub fn to_us(abs: Absolute) u64 {
                return @intFromEnum(abs);
            }

            pub fn is_reached_by(deadline: Absolute, point: Absolute) bool {
                return deadline.to_us() <= point.to_us();
            }

            pub fn diff(future: Absolute, past: Absolute) Duration {
                return Duration.from_us(future.to_us() - past.to_us());
            }

            pub fn add_duration(abs: Absolute, dur: Duration) Absolute {
                return Absolute.from_us(abs.to_us() + dur.to_us());
            }
        };

        // Lifted from microzig source
        pub const Duration = enum(u64) {
            _,

            pub fn from_us(us: u64) Duration {
                return @as(Duration, @enumFromInt(us));
            }

            pub fn from_ms(ms: u64) Duration {
                return from_us(1000 * ms);
            }

            pub fn to_us(duration: Duration) u64 {
                return @intFromEnum(duration);
            }

            pub fn less_than(self: Duration, other: Duration) bool {
                return self.to_us() < other.to_us();
            }

            pub fn minus(self: Duration, other: Duration) Duration {
                return from_us(self.to_us() - other.to_us());
            }

            pub fn plus(self: Duration, other: Duration) Duration {
                return from_us(self.to_us() + other.to_us());
            }
        };
    };
};
