pub fn makeCallback(comptime PayloadType: type) type {
    return struct {
        const Self = @This();
        context: *anyopaque,
        handler: *const fn (ctx: *anyopaque, state: PayloadType) anyerror!void,

        pub fn advise(self: Self, state: PayloadType) !void {
            try self.handler(self.context, state);
        }
    };
}
