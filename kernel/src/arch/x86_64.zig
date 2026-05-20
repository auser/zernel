pub const io = @import("x86_64/io.zig");
pub const keyboard = @import("x86_64/keyboard.zig");
pub const paging = @import("x86_64/paging.zig");
pub const serial = @import("x86_64/serial.zig");

pub const KeyboardKey = keyboard.DecodedKey;

pub fn initEarlyDebug() void {
    serial.init();
}

pub fn writeEarlyDebug(message: []const u8) void {
    serial.writeString(message);
}

pub fn readEarlyDebug() ?u8 {
    return serial.readByte();
}

pub fn readKeyboardKey() ?KeyboardKey {
    const scancode = keyboard.readScancode() orelse return null;
    return keyboard.decode(scancode);
}

pub fn initTimer() void {
    // External interrupts stay disabled until IDT/PIC/APIC setup is complete.
}

pub fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
