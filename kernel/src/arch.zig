const builtin = @import("builtin");

const current = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("unsupported kernel architecture"),
};

pub const paging = current.paging;
pub const KeyboardKey = current.KeyboardKey;

pub fn initEarlyDebug() void {
    current.initEarlyDebug();
}

pub fn writeEarlyDebug(message: []const u8) void {
    current.writeEarlyDebug(message);
}

pub fn readEarlyDebug() ?u8 {
    return current.readEarlyDebug();
}

pub fn readKeyboardKey() ?KeyboardKey {
    return current.readKeyboardKey();
}

pub fn initTimer() void {
    current.initTimer();
}

pub fn halt() noreturn {
    current.halt();
}
