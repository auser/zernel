const boot_info = @import("../../boot/info.zig");
const BootInfo = boot_info.BootInfo;
const mapping = @import("../../mem/mapping.zig");
const mem_page = @import("../../mem/page.zig");
const mem_virtual = @import("../../mem/virtual.zig");
const panic = @import("../../utils/panic.zig").panic;
const pmm = @import("../../mem/pmm.zig");

pub const page_size: usize = 4096;
pub const Permissions = mapping.Permissions;
pub const MapError = mapping.PermissionError || error{
    UnalignedAddress,
};
pub const UnmapError = error{
    UnalignedAddress,
};
pub const StackMapError = MapError || mapping.CellMappingError || mem_virtual.LayoutError || error{
    InvalidStack,
    MissingOwner,
    GuardPageMapped,
};
const page_size_2mib: usize = 2 * 1024 * 1024;
const page_size_1gib: usize = 1024 * 1024 * 1024;

const flag_present: u64 = 1 << 0;
const flag_huge: u64 = 1 << 7;
const address_mask: u64 = 0x000f_ffff_ffff_f000;

pub fn readCr3() usize {
    return asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> usize),
    );
}

pub fn activeRootTablePhys() usize {
    return readCr3() & ~@as(usize, 0xfff);
}

pub fn pml4Index(virt: usize) usize {
    return (virt >> 39) & 0x1ff;
}

pub fn pdptIndex(virt: usize) usize {
    return (virt >> 30) & 0x1ff;
}

pub fn pdIndex(virt: usize) usize {
    return (virt >> 21) & 0x1ff;
}

pub fn ptIndex(virt: usize) usize {
    return (virt >> 12) & 0x1ff;
}

pub fn pageOffset(virt: usize) usize {
    return virt & 0xfff;
}

pub fn mapPage(info: *const BootInfo, virt: usize, phys: usize, permissions: Permissions) MapError!void {
    try permissions.validateKernelMapping();
    if ((virt & (page_size - 1)) != 0 or (phys & (page_size - 1)) != 0) {
        return error.UnalignedAddress;
    }

    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pdpt = ensureNextTable(info, &pml4[pml4Index(virt)]);
    const pd = ensureNextTable(info, &pdpt[pdptIndex(virt)]);
    const pt = ensureNextTable(info, &pd[pdIndex(virt)]);

    pt[ptIndex(virt)] = makeEntry(phys, entryFlagsFromPermissions(permissions));
    invlpg(virt);
}

pub fn unmapPage(info: *const BootInfo, virt: usize) void {
    const pte = findPte(info, virt) orelse panic("unmapPage: unmapped address");
    pte.* = 0;
    invlpg(virt);
}

pub fn tryUnmapPage(info: *const BootInfo, virt: usize) UnmapError!bool {
    if (!mem_page.isAligned(virt)) return error.UnalignedAddress;
    const pte = findPte(info, virt) orelse return false;
    pte.* = 0;
    invlpg(virt);
    return true;
}

pub fn mapStackPages(
    info: *const BootInfo,
    layout: mem_virtual.StackLayout,
    cell_id: u32,
    pages: []const usize,
    permissions: Permissions,
) StackMapError!void {
    if (pages.len != layout.mapped_pages) return error.InvalidStack;

    try ensureStackGuardPagesUnmapped(info, layout);

    var mapped: usize = 0;
    errdefer rollbackMappedStackPages(info, layout, mapped);

    while (mapped < pages.len) : (mapped += 1) {
        const phys = pages[mapped];
        const owner = pmm.pageOwner(phys) orelse return error.MissingOwner;
        try mapping.validateCellPageMapping(cell_id, owner, permissions);
        try mapPage(info, try layout.mappedPage(mapped), phys, permissions);
    }

    try ensureStackGuardPagesUnmapped(info, layout);
}

pub const MappingInfo = struct {
    phys: usize,
    flags: u64,
    page_size: usize,
};

pub fn translate(info: *const BootInfo, virt: usize) ?MappingInfo {
    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pml4e = pml4[pml4Index(virt)];
    if (!isPresent(pml4e)) return null;

    const pdpt = tableFromEntry(info, pml4e);
    const pdpte = pdpt[pdptIndex(virt)];
    if (!isPresent(pdpte)) return null;
    if (isHuge(pdpte)) return huge1GiBMapping(pdpte, virt);

    const pd = tableFromEntry(info, pdpte);
    const pde = pd[pdIndex(virt)];
    if (!isPresent(pde)) return null;
    if (isHuge(pde)) return huge2MiBMapping(pde, virt);

    const pt = tableFromEntry(info, pde);
    const pte = pt[ptIndex(virt)];
    if (!isPresent(pte)) return null;

    return .{
        .phys = entryPhys(pte) + pageOffset(virt),
        .flags = rawEntry(pte),
        .page_size = 4096,
    };
}

const Entry = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    huge: bool,
    global: bool,
    ignored_0: u3,
    address: u40,
    ignored_1: u11,
    no_execute: bool,
};

const Table = [512]Entry;

fn isPresent(entry: Entry) bool {
    return entry.present;
}

fn isHuge(entry: Entry) bool {
    return entry.huge;
}

fn entryPhys(entry: Entry) usize {
    return @as(usize, entry.address) << 12;
}

fn tableFromPhys(info: *const BootInfo, phys: usize) *Table {
    return @ptrFromInt(boot_info.physToHhdm(info, phys));
}

fn tableFromEntry(info: *const BootInfo, entry: Entry) *Table {
    return tableFromPhys(info, entryPhys(entry));
}

fn rawEntry(entry: Entry) u64 {
    return @bitCast(entry);
}

fn entryFromRaw(raw: u64) Entry {
    return @bitCast(raw);
}

fn huge1GiBMapping(entry: Entry, virt: usize) MappingInfo {
    const base = entryPhys(entry);
    const offset = virt & (page_size_1gib - 1);

    return .{
        .phys = base + offset,
        .flags = rawEntry(entry),
        .page_size = page_size_1gib,
    };
}

fn huge2MiBMapping(entry: Entry, virt: usize) MappingInfo {
    const base = entryPhys(entry);
    const offset = virt & (page_size_2mib - 1);

    return .{
        .phys = base + offset,
        .flags = rawEntry(entry),
        .page_size = page_size_2mib,
    };
}

fn ensureNextTable(info: *const BootInfo, entry: *Entry) *Table {
    if (isPresent(entry.*)) {
        if (isHuge(entry.*)) {
            panic("ensureNextTable: huge mapping blocks table walk");
        }
        return tableFromEntry(info, entry.*);
    }

    const table_phys = pmm.allocPageOwned(.{ .kind = .page_table }) orelse panic("ensureNextTable: out of pages");
    const table = tableFromPhys(info, table_phys);
    @memset(@as([*]u8, @ptrCast(table))[0..page_size], 0);

    entry.* = makeEntry(table_phys, .{
        .present = true,
        .writable = true,
    });

    return table;
}

fn findPte(info: *const BootInfo, virt: usize) ?*Entry {
    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pml4e = pml4[pml4Index(virt)];
    if (!isPresent(pml4e)) return null;
    if (isHuge(pml4e)) return null;

    const pdpt = tableFromEntry(info, pml4e);
    const pdpte = pdpt[pdptIndex(virt)];
    if (!isPresent(pdpte)) return null;
    if (isHuge(pdpte)) return null;

    const pd = tableFromEntry(info, pdpte);
    const pde = pd[pdIndex(virt)];
    if (!isPresent(pde)) return null;
    if (isHuge(pde)) return null;

    const pt = tableFromEntry(info, pde);
    return &pt[ptIndex(virt)];
}

fn ensureStackGuardPagesUnmapped(info: *const BootInfo, layout: mem_virtual.StackLayout) StackMapError!void {
    var virt = layout.base;
    while (virt < layout.mappedBase()) : (virt += page_size) {
        _ = try tryUnmapPage(info, virt);
        if (translate(info, virt) != null) return error.GuardPageMapped;
    }

    virt = layout.highGuardBase();
    while (virt < layout.end()) : (virt += page_size) {
        _ = try tryUnmapPage(info, virt);
        if (translate(info, virt) != null) return error.GuardPageMapped;
    }
}

fn rollbackMappedStackPages(info: *const BootInfo, layout: mem_virtual.StackLayout, mapped: usize) void {
    var index: usize = 0;
    while (index < mapped) : (index += 1) {
        const virt = layout.mappedPage(index) catch return;
        _ = tryUnmapPage(info, virt) catch {};
    }
}

fn makeEntryRaw(phys: usize, flags: u64) Entry {
    if ((phys & (page_size - 1)) != 0) {
        panic("makeEntryRaw: unaligned physical address");
    }
    return entryFromRaw((phys & address_mask) | flags);
}

fn entryFlagsFromPermissions(permissions: Permissions) EntryFlags {
    return .{
        .present = true,
        .writable = permissions.write,
        .user = permissions.user,
        .no_execute = !permissions.execute,
    };
}

fn makeEntry(phys: usize, flags: EntryFlags) Entry {
    if ((phys & (page_size - 1)) != 0) {
        panic("makeEntry: unaligned physical address");
    }

    return .{
        .present = flags.present,
        .writable = flags.writable,
        .user = flags.user,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = flags.huge,
        .global = false,
        .ignored_0 = 0,
        .address = @intCast(phys >> 12),
        .ignored_1 = 0,
        .no_execute = flags.no_execute,
    };
}

const EntryFlags = struct {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    huge: bool = false,
    no_execute: bool = false,
};

fn invlpg(virt: usize) void {
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (virt),
        : "memory");
}
