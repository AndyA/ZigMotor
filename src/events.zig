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
        hot: u8 = 0,

        pub const empty: Self = .{};

        pub fn emit(self: *Self, payload: PayloadType) void {
            assert(self.hot == 0);
            self.hot = self.used;
            defer self.hot = 0;

            const active = self.slots[0..self.hot];
            for (active) |slot| {
                slot.handler(slot.context, payload);
            }

            // Prune
            var out_pos: u8 = 0;
            for (active) |slot| {
                if (!slot.mortal) {
                    self.slots[out_pos] = slot;
                    out_pos += 1;
                }
            }
            self.used = out_pos;
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

        pub fn addHandler(self: *Self, handler: HandlerType, context: *anyopaque) void {
            assert(self.find(handler, context) == null);
            self.add(handler, context, false);
        }

        pub fn once(self: *Self, handler: HandlerType, context: *anyopaque) void {
            self.add(handler, context, true);
        }

        fn find(self: Self, handler: HandlerType, context: *anyopaque) ?u8 {
            for (self.slots[0..self.used], 0..) |slot, index| {
                if (slot.handler == handler and slot.context == context)
                    return index;
            }
            return null;
        }

        pub fn removeHandler(self: *Self, handler: HandlerType, context: *anyopaque) void {
            const index = self.find(handler, context).?;
            if (index < self.hot) {
                // Don't delete any slots that are in the range emit is currently looping
                // over. Instead mark them as mortal so that emit will prune them.
                self.slots[index].mortal = true;
            } else {
                @memmove(
                    &self.slots[index .. self.used - 1],
                    &self.slots[index + 1 .. self.used],
                );
                self.used -= 1;
            }
        }
    };
}
