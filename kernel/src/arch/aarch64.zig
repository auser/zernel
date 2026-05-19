pub fn initEarlyDebug() void {}

pub fn writeEarlyDebug(_: []const u8) void {}

pub fn halt() noreturn {
    asm volatile ("msr daifset, #0xf");
    while (true) {
        asm volatile ("wfi");
    }
}
