pub const paging = @import("aarch64/paging.zig");

pub const KeyboardKey = struct {
    code: u16,
    pressed: bool,
};

pub fn initEarlyDebug() void {}

pub fn writeEarlyDebug(_: []const u8) void {}

pub fn readEarlyDebug() ?u8 {
    return null;
}

pub fn readKeyboardKey() ?KeyboardKey {
    return null;
}

pub fn initTimer() void {}

pub fn halt() noreturn {
    asm volatile ("msr daifset, #0xf");
    while (true) {
        asm volatile ("wfi");
    }
}
