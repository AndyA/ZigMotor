pub const VoidCallback = struct {
    const Self = @This();
    context: *anyopaque,
    handler: *const fn (ctx: *anyopaque) anyerror!void,

    pub fn advise(self: Self) !void {
        try self.handler(self.context);
    }
};

pub fn makeCallback(comptime PayloadType: type) type {
    if (@sizeOf(PayloadType) == 0)
        return VoidCallback;

    return struct {
        const Self = @This();
        context: *anyopaque,
        handler: *const fn (ctx: *anyopaque, state: PayloadType) anyerror!void,

        pub fn advise(self: Self, state: PayloadType) !void {
            try self.handler(self.context, state);
        }
    };
}
