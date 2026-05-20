pub const io = @import("x86_64/io.zig");
pub const paging = @import("x86_64/paging.zig");
pub const serial = @import("x86_64/serial.zig");

pub fn initEarlyDebug() void {
    serial.init();
}

pub fn writeEarlyDebug(message: []const u8) void {
    serial.writeString(message);
}

pub fn readEarlyDebug() ?u8 {
    return serial.readByte();
}

pub fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
