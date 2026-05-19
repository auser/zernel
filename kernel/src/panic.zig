const arch = @import("arch.zig");
const klog = @import("klog.zig");

pub fn panic(msg: []const u8) noreturn {
    klog.err("PANIC");
    klog.err(msg);
    arch.halt();
}
