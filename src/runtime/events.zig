const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;

pub fn Emitter(comptime PayloadType: type, comptime size: u8) type {
    return struct {
        const is_void = @sizeOf(PayloadType) == 0;
        const Self = @This();

        pub const HandlerType = if (is_void)
            fn (ctx: *anyopaque) anyerror!void
        else
            fn (ctx: *anyopaque, payload: PayloadType) anyerror!void;

        const shim = if (is_void)
            struct {
                pub fn emit(self: *Self) !void {
                    try self.emitPayload({});
                }
            }
        else
            struct {
                pub fn emit(self: *Self, payload: PayloadType) !void {
                    try self.emitPayload(payload);
                }
            };

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

        pub const emit = shim.emit;

        fn emitPayload(self: *Self, payload: PayloadType) !void {
            assert(self.hot == 0);
            self.hot = self.used;
            defer {
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
                self.hot = 0;
            }

            for (self.slots[0..self.hot]) |slot| {
                if (is_void)
                    try slot.handler(slot.context)
                else
                    try slot.handler(slot.context, payload);
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
            if (mortal) self.mortals += 1;
        }

        fn find(self: Self, from: u8, handler: HandlerType, context: *anyopaque) ?u8 {
            for (self.slots[from..self.used], from..) |slot, index| {
                if (slot.handler == handler and slot.context == context)
                    return @intCast(index);
            }
            return null;
        }

        fn removeAtIndex(self: *Self, index: u8) u8 {
            if (index < self.hot) {
                // Don't delete any slots that are in the range emit is currently looping
                // over. Instead mark them as mortal so that emit will prune them.
                if (!self.slots[index].mortal) self.mortals += 1;
                self.slots[index].mortal = true;
                return 1;
            } else {
                if (self.slots[index].mortal) self.mortals -= 1;
                @memmove(
                    self.slots[index .. self.used - 1],
                    self.slots[index + 1 .. self.used],
                );
                self.used -= 1;
                return 0;
            }
        }

        pub fn addListener(self: *Self, handler: HandlerType, context: *anyopaque) void {
            assert(self.find(0, handler, context) == null);
            self.add(handler, context, false);
        }

        pub fn once(self: *Self, handler: HandlerType, context: *anyopaque) void {
            assert(self.find(self.hot, handler, context) == null);
            self.add(handler, context, true);
        }

        pub fn removeListener(self: *Self, handler: HandlerType, context: *anyopaque) void {
            const index = self.find(0, handler, context).?;
            _ = self.removeAtIndex(index);
        }

        pub fn removeAll(self: *Self, context: *anyopaque) void {
            var index: u8 = 0;
            while (index < self.used) {
                if (self.slots[index].context == context)
                    index += self.removeAtIndex(index)
                else
                    index += 1;
            }
        }
    };
}

test Emitter {
    const Payload = struct {
        ee: *Emitter(@This(), 5),
        more: bool = false,
        stop_all: bool = false,
    };

    const EventTarget = struct {
        const Self = @This();

        seen_on_event: usize = 0,
        seen_more: usize = 0,
        seen_on_once: usize = 0,
        seen_on_mortal: usize = 0,

        pub fn onEvent(ctx: *anyopaque, payload: Payload) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.seen_on_event += 1;
            if (payload.more)
                self.seen_more += 1;
        }

        pub fn onOnce(ctx: *anyopaque, payload: Payload) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.seen_on_once += 1;

            if (payload.more)
                payload.ee.once(onOnce, self);
        }

        pub fn onMortal(ctx: *anyopaque, payload: Payload) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.seen_on_mortal += 1;

            if (!payload.more)
                payload.ee.removeListener(onMortal, self);
            if (payload.stop_all)
                payload.ee.removeAll(self);
        }
    };

    var ee: Emitter(Payload, 5) = .empty;

    var t1: EventTarget = .{};

    ee.addListener(EventTarget.onEvent, &t1);
    try expectEqual(0, t1.seen_on_event);
    try expectEqual(0, t1.seen_more);
    try ee.emit(.{ .ee = &ee });
    try expectEqual(1, t1.seen_on_event);
    try expectEqual(0, t1.seen_more);

    var t2: EventTarget = .{};

    ee.addListener(EventTarget.onEvent, &t2);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(2, t1.seen_on_event);
    try expectEqual(1, t1.seen_more);
    try expectEqual(1, t2.seen_on_event);
    try expectEqual(1, t2.seen_more);

    ee.removeListener(EventTarget.onEvent, &t1);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(2, t1.seen_on_event);
    try expectEqual(1, t1.seen_more);
    try expectEqual(2, t2.seen_on_event);
    try expectEqual(2, t2.seen_more);

    ee.once(EventTarget.onOnce, &t1);
    try expectEqual(0, t1.seen_on_once);
    try ee.emit(.{ .ee = &ee });
    try expectEqual(1, t1.seen_on_once);
    try ee.emit(.{ .ee = &ee });
    try expectEqual(1, t1.seen_on_once);

    ee.once(EventTarget.onOnce, &t1);
    try expectEqual(1, t1.seen_on_once);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(2, t1.seen_on_once);
    try ee.emit(.{ .ee = &ee });
    try expectEqual(3, t1.seen_on_once);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(3, t1.seen_on_once);

    ee.addListener(EventTarget.onMortal, &t1);
    try expectEqual(0, t1.seen_on_mortal);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(1, t1.seen_on_mortal);
    try ee.emit(.{ .ee = &ee });
    try expectEqual(2, t1.seen_on_mortal);
    try ee.emit(.{ .ee = &ee });
    try expectEqual(2, t1.seen_on_mortal);

    try expectEqual(1, ee.used);

    ee.addListener(EventTarget.onEvent, &t1);
    ee.addListener(EventTarget.onMortal, &t1);

    try expectEqual(3, ee.used);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(3, t1.seen_on_event);
    try expectEqual(3, t1.seen_on_mortal);
    try expectEqual(11, t2.seen_on_event);

    ee.removeAll(&t1);

    try expectEqual(1, ee.used);
    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(3, t1.seen_on_event);
    try expectEqual(3, t1.seen_on_mortal);
    try expectEqual(12, t2.seen_on_event);

    ee.addListener(EventTarget.onEvent, &t1);
    ee.addListener(EventTarget.onMortal, &t1);

    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(4, t1.seen_on_event);
    try expectEqual(4, t1.seen_on_mortal);
    try expectEqual(13, t2.seen_on_event);

    try ee.emit(.{ .ee = &ee, .more = true, .stop_all = true });
    try expectEqual(5, t1.seen_on_event);
    try expectEqual(5, t1.seen_on_mortal);
    try expectEqual(14, t2.seen_on_event);

    try expectEqual(1, ee.used);

    try ee.emit(.{ .ee = &ee, .more = true });
    try expectEqual(5, t1.seen_on_event);
    try expectEqual(5, t1.seen_on_mortal);
    try expectEqual(15, t2.seen_on_event);
}

test "Emitter with void PayloadType" {
    const EventTarget = struct {
        const Self = @This();

        seen_on_event: usize = 0,

        pub fn onEvent(ctx: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.seen_on_event += 1;
        }
    };

    var ee: Emitter(void, 5) = .empty;
    var t1: EventTarget = .{};

    ee.addListener(EventTarget.onEvent, &t1);
    try ee.emit();
    try expectEqual(1, t1.seen_on_event);
}
