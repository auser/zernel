const limine = @import("limine");
const klog = @import("../klog.zig");
const panic = @import("../panic.zig").panic;

pub export var base_revision: limine.BaseRevision linksection(".limine_requests") = .{
    .revision = 3,
};

pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};
pub export var memory_map_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
pub export var kernel_address_request: limine.KernelAddressRequest linksection(".limine_requests") = .{};

pub const BootInfo = struct {
    framebuffer: *limine.Framebuffer,
    memory_map: *limine.MemoryMapResponse,
    hhdm_offset: usize,
    kernel_physical_base: usize,
    kernel_virtual_base: usize,
};

pub fn load() BootInfo {
    const framebuffer_response = framebuffer_request.response orelse panic("missing framebuffer response");
    if (framebuffer_response.framebuffer_count == 0) {
        panic("no framebuffers available");
    }

    const memory_map = memory_map_request.response orelse panic("missing memory map");
    const hhdm = hhdm_request.response orelse panic("missing hhdm");
    const kernel_address = kernel_address_request.response orelse panic("missing kernel address");

    return .{
        .framebuffer = framebuffer_response.framebuffers()[0],
        .memory_map = memory_map,
        .hhdm_offset = @intCast(hhdm.offset),
        .kernel_physical_base = @intCast(kernel_address.physical_base),
        .kernel_virtual_base = @intCast(kernel_address.virtual_base),
    };
}

pub fn validate(info: *const BootInfo) void {
    if (info.framebuffer.bpp != 32) {
        panic("unsupported framebuffer format");
    }

    if (@intFromPtr(info.framebuffer.address) == 0) {
        panic("framebuffer address is null");
    }

    if (info.memory_map.entry_count == 0) {
        panic("memory map is empty");
    }

    if (info.hhdm_offset == 0) {
        panic("missing hhdm offset");
    }

    if (info.kernel_physical_base == 0) {
        panic("missing kernel physical base");
    }

    if (info.kernel_virtual_base == 0) {
        panic("missing kernel virtual base");
    }
}

pub fn logFramebuffer(info: *const BootInfo) void {
    const framebuffer = info.framebuffer;

    klog.info("framebuffer");
    klog.labelDec("  width", @intCast(framebuffer.width));
    klog.labelDec("  height", @intCast(framebuffer.height));
    klog.labelDec("  pitch", @intCast(framebuffer.pitch));
    klog.labelDec("  bpp", @intCast(framebuffer.bpp));
    klog.labelHex("  address", @intFromPtr(framebuffer.address));
}

pub fn logMemoryMap(info: *const BootInfo) void {
    var usable_total: usize = 0;
    var usable_ranges: usize = 0;
    var highest_usable: usize = 0;

    klog.info("memory map");

    for (info.memory_map.entries()) |entry| {
        const base: usize = @intCast(entry.base);
        const length: usize = @intCast(entry.length);
        const end = base + length;

        klog.labelHex("  base", base);
        klog.labelHex("  length", length);
        klog.labelDec("  kind", @intFromEnum(entry.kind));

        if (entry.kind == .usable) {
            usable_total += length;
            usable_ranges += 1;
            if (end > highest_usable) {
                highest_usable = end;
            }
        }
    }

    klog.labelDec("usable ranges", usable_ranges);
    klog.labelHex("usable bytes", usable_total);
    klog.labelHex("highest usable", highest_usable);
}

pub fn logAddressInfo(info: *const BootInfo) void {
    klog.info("address info");
    klog.labelHex("  hhdm offset", info.hhdm_offset);
    klog.labelHex("  kernel physical", info.kernel_physical_base);
    klog.labelHex("  kernel virtual", info.kernel_virtual_base);
}

pub fn physToHhdm(info: *const BootInfo, phys: usize) usize {
    return info.hhdm_offset + phys;
}

pub fn hhdmToPhys(info: *const BootInfo, virt: usize) usize {
    return virt - info.hhdm_offset;
}
