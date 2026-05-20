const mapping = @import("../../mem/mapping.zig");
const mem_virtual = @import("../../mem/virtual.zig");
const boot_info = @import("../../boot/info.zig");

pub const page_size: usize = 4096;
pub const Permissions = mapping.Permissions;
pub const StackMapError = error{
    Unsupported,
};

pub fn pageOffset(virt: usize) usize {
    return virt & (page_size - 1);
}

pub fn mapStackPages(
    _: *const boot_info.BootInfo,
    _: mem_virtual.StackLayout,
    _: u32,
    _: []const usize,
    _: Permissions,
) StackMapError!void {
    return error.Unsupported;
}
