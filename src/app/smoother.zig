const std = @import("std");
const assert = std.debug.assert;

pub fn Smoother(comptime T: type, comptime size: u8) type {
    assert(size != 0);
    return struct {
        const Self = @This();
        pub const Total = @Int(
            @typeInfo(T).int.signedness,
            @typeInfo(T).int.bits + std.math.log2_int_ceil(u8, size),
        );

        samples: [size]T = undefined,
        total: Total = 0,
        pos: u8 = 0,
        used: u8 = 0,

        pub fn update(self: *Self, value: T) T {
            assert(self.pos < size);
            assert(self.used <= size);

            if (self.used == size)
                self.total -= self.samples[self.pos]
            else
                self.used += 1;

            self.total += value;
            self.samples[self.pos] = value;
            self.pos += 1;
            if (self.pos == size)
                self.pos = 0;

            return @intCast(self.total / self.used);
        }
    };
}
