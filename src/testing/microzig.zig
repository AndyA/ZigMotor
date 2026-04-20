const std = @import("std");
const Allocator = std.mem.Allocator;

const events = @import("../runtime/events.zig");

pub const drivers = struct {
    pub const base = struct {
        pub const Digital_IO = struct {
            const Self = @This();

            pub const State = enum(u1) {
                low = 0,
                high = 1,

                pub fn invert(state: State) State {
                    return @as(State, @enumFromInt(~@intFromEnum(state)));
                }

                pub fn value(state: State) u1 {
                    return @intFromEnum(state);
                }
            };

            pub const Direction = enum { input, output };

            const Driver = struct {
                state: State = .low,
                direction: Direction = .input,
            };

            pub const Event = struct {
                const Reason = enum { WRITE, SET_DIRECTION };
                name: []const u8,
                driver: Driver,
                reason: Reason,
            };

            pub const Emitter = events.Emitter(Event, 2);

            name: []const u8,
            emitter: *Emitter,
            driver: *Driver,

            pub fn init(allocator: Allocator, name: []const u8, emitter: *Emitter) !Self {
                return .{
                    .name = try allocator.dupe(u8, name),
                    .emitter = emitter,
                    .driver = try allocator.create(Driver),
                };
            }

            pub fn deinit(self: Self, allocator: Allocator) void {
                allocator.free(self.name);
                allocator.destroy(self.driver);
            }

            fn emit(self: Self, reason: Event.Reason) void {
                self.emitter.emit(.{
                    .name = self.name,
                    .driver = self.driver.*,
                    .reason = reason,
                }) catch unreachable;
            }

            pub fn write(self: Self, state: State) !void {
                self.driver.state = state;
                self.emit(.WRITE);
            }

            pub fn set_direction(self: Self, direction: Direction) !void {
                self.driver.direction = direction;
                self.emit(.SET_DIRECTION);
            }
        };
    };
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
