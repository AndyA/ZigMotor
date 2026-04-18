const std = @import("std");
const assert = std.debug.assert;

pub fn Emitter(comptime PayloadType: type, comptime size: u8) type {
    return struct {
        const Self = @This();
        pub const HandlerType = fn (ctx: *anyopaque, payload: PayloadType) void;

        const SlotType = struct {
            handler: *const HandlerType,
            context: *anyopaque,
            mortal: bool,
        };

        slots: [size]SlotType = undefined,
        used: u8 = 0,
        mortals: u8 = 0,
        hot: u8 = 0,

        pub const empty: Self = .{};

        pub fn emit(self: *Self, payload: PayloadType) void {
            assert(self.hot == 0);
            self.hot = self.used;
            defer self.hot = 0;

            for (self.slots[0..self.hot]) |slot| {
                slot.handler(slot.context, payload);
            }

            if (self.mortals > 0) {
                // Prune any mortals from the hot region.
                var out_pos: u8 = 0;
                for (0..self.used) |in_pos| {
                    // Copy any that are outside the hot region or immortal
                    if (in_pos >= self.hot or !self.slots[in_pos].mortal) {
                        self.slots[out_pos] = self.slots[in_pos];
                        out_pos += 1;
                    } else {
                        self.mortals -= 1;
                    }
                }
                self.used = out_pos;
            }
        }

        fn add(self: *Self, handler: HandlerType, context: *anyopaque, mortal: bool) void {
            assert(self.used < size);
            self.slots[self.used] = .{
                .handler = handler,
                .context = context,
                .mortal = mortal,
            };
            self.used += 1;
        }

        pub fn addListener(self: *Self, handler: HandlerType, context: *anyopaque) void {
            assert(self.find(0, handler, context) == null);
            self.add(handler, context, false);
        }

        pub fn once(self: *Self, handler: HandlerType, context: *anyopaque) void {
            assert(self.find(self.hot, handler, context) == null);
            self.add(handler, context, true);
            self.mortals += 1;
        }

        fn find(self: Self, from: u8, handler: HandlerType, context: *anyopaque) ?u8 {
            for (self.slots[from..self.used], from..) |slot, index| {
                if (slot.handler == handler and slot.context == context)
                    return index;
            }
            return null;
        }

        pub fn removeListener(self: *Self, handler: HandlerType, context: *anyopaque) void {
            const index = self.find(0, handler, context).?;
            if (index < self.hot) {
                // Don't delete any slots that are in the range emit is currently looping
                // over. Instead mark them as mortal so that emit will prune them.
                if (!self.slots[index].mortal) self.mortals += 1;
                self.slots[index].mortal = true;
            } else {
                if (self.slots[index].mortal) self.mortals -= 1;
                @memmove(
                    &self.slots[index .. self.used - 1],
                    &self.slots[index + 1 .. self.used],
                );
                self.used -= 1;
            }
        }
    };
}
