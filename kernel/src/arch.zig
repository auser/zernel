const builtin = @import("builtin");

const current = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("unsupported kernel architecture"),
};

pub fn initEarlyDebug() void {
    current.initEarlyDebug();
}

pub fn writeEarlyDebug(message: []const u8) void {
    current.writeEarlyDebug(message);
}

pub fn halt() noreturn {
    current.halt();
}
