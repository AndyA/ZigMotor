const std = @import("std");
const assert = std.debug.assert;

pub fn Emitter(comptime PayloadType: type, comptime size: u8) type {
    return struct {
        const Self = @This();
        pub const HandlerType = fn (ctx: *anyopaque, payload: PayloadType) void;

        const SlotType = struct {
            handler: *const HandlerType,
            context: *anyopaque,
        };

        slots: [size]SlotType = undefined,
        used: u8 = 0,

        pub const empty: Self = .{};

        pub fn emit(self: Self, payload: PayloadType) void {
            for (self.slots[0..self.used]) |slot| {
                slot.handler(slot.context, payload);
            }
        }

        pub fn addHandler(self: *Self, handler: HandlerType, context: *anyopaque) void {
            assert(self.used < size);
            self.slots[self.used] = .{ .handler = handler, .context = context };
            self.used += 1;
        }

        fn find(self: Self, handler: HandlerType, context: *anyopaque) u8 {
            for (self.slots[0..self.used], 0..) |slot, i| {
                if (slot.handler == handler and slot.context == context)
                    return i;
            }
            unreachable;
        }

        pub fn removeHandler(self: *Self, handler: HandlerType, context: *anyopaque) void {
            const index = self.find(handler, context);
            @memmove(
                &self.slots[index .. self.used - 1],
                &self.slots[index + 1 .. self.used],
            );
            self.used -= 1;
        }
    };
}
