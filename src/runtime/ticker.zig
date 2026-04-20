const events = @import("events.zig");

pub const TickerConfig = struct {
    Member: type,
    event_handler_size: ?u8 = null,
};

pub fn makeTicker(comptime config: TickerConfig) type {
    _ = config;
    return struct {};
}

test makeTicker {
    const Member = struct {};
    const Ticker = makeTicker(.{ .Member = Member });
    const t: Ticker = .{};
    _ = t;
}
