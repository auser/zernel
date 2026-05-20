const builtin = @import("builtin");
const page = @import("page.zig");
const panic = if (builtin.is_test) testPanic else @import("../utils/panic.zig").panic;
const limine = if (builtin.is_test) test_limine else @import("limine");
const boot_info = if (builtin.is_test) test_boot_info else @import("../boot/info.zig");

const test_limine = struct {
    pub const MemoryMapKind = enum {
        usable,
        reserved,
    };

    pub const MemoryMapEntry = struct {
        base: u64,
        length: u64,
        kind: MemoryMapKind,
    };

    pub const MemoryMapResponse = struct {
        items: []const MemoryMapEntry,

        pub fn entries(self: *MemoryMapResponse) []const MemoryMapEntry {
            return self.items;
        }
    };
};

const test_boot_info = struct {
    pub const BootInfo = struct {
        memory_map: *limine.MemoryMapResponse,
        hhdm_offset: usize,
    };

    pub fn physToHhdm(info: *const BootInfo, phys: usize) usize {
        return info.hhdm_offset + phys;
    }
};

fn testPanic(message: []const u8) noreturn {
    @panic(message);
}

pub const Stats = struct {
    total_pages: usize,
    free_pages: usize,
    used_pages: usize,
    reserved_pages: usize,
    kernel_pages: usize,
    heap_pages: usize,
    page_table_pages: usize,
    cell_pages: usize,
};

pub const OwnerKind = enum(u8) {
    free,
    reserved,
    kernel,
    heap,
    page_table,
    cell,
};

pub const PageOwner = struct {
    kind: OwnerKind = .reserved,
    cell_id: u32 = 0,

    pub fn cell(id: u32) PageOwner {
        return .{ .kind = .cell, .cell_id = id };
    }
};

pub const RangeError = error{
    NotInitialized,
    UnalignedAddress,
    EmptyRange,
    OutOfRange,
    DoubleFree,
    Overflow,
    OwnerMismatch,
};

pub fn init(info: *const boot_info.BootInfo) void {
    // Init
    const highest = findHighestUsable(info.memory_map);
    const total_pages = (page.alignUpChecked(highest) orelse panic("pmm: memory size overflow")) / page.size;
    const bitmap_bytes = bitmapBytes(total_pages);
    const owner_bytes = ownerBytes(total_pages) orelse panic("pmm: owner table size overflow");
    const bitmap_storage_bytes = page.alignUpChecked(bitmap_bytes) orelse panic("pmm: bitmap size overflow");
    const owner_storage_bytes = page.alignUpChecked(owner_bytes) orelse panic("pmm: owner size overflow");
    const metadata_bytes = checkedRangeEnd(bitmap_storage_bytes, owner_storage_bytes) catch
        panic("pmm: metadata size overflow");

    const bitmap_phys =
        findBitmapStorage(info.memory_map, metadata_bytes) orelse
        panic("no pmm metadata storage");
    const owners_phys = checkedRangeEnd(bitmap_phys, bitmap_storage_bytes) catch
        panic("pmm: owner table address overflow");

    const bitmap_virt = boot_info.physToHhdm(info, bitmap_phys);
    const owners_virt = boot_info.physToHhdm(info, owners_phys);
    const bitmap: []u8 = @as([*]u8, @ptrFromInt(bitmap_virt))[0..bitmap_bytes];
    const owners: []PageOwner = @as([*]PageOwner, @ptrFromInt(owners_virt))[0..total_pages];

    // Clear the memory
    @memset(bitmap, 0xff);
    @memset(owners, .{});

    state = .{
        .bitmap = bitmap,
        .owners = owners,
        .total_pages = total_pages,
        .free_pages = 0,
    };

    markUsableMemoryFree(info.memory_map);
    reserveRangeOwned(bitmap_phys, metadata_bytes, .{ .kind = .kernel });
    reservePageOwned(0, .{ .kind = .kernel });
}

pub fn allocPage() ?usize {
    return allocPageOwned(.{ .kind = .kernel });
}

pub fn allocPageOwned(owner: PageOwner) ?usize {
    if (owner.kind == .free) return null;
    var s = &(state orelse return null);

    var index: usize = 0;
    while (index < s.total_pages) : (index += 1) {
        if (!isUsed(s.bitmap, index)) {
            setUsed(s.bitmap, index, true);
            s.owners[index] = owner;
            s.free_pages -= 1;
            return index * page.size;
        }
    }

    return null;
}

pub fn freePage(phys: usize) void {
    var s = &(state orelse panic("pmm not initialized"));

    if (!page.isAligned(phys)) {
        panic("freePage: unaligned address");
    }

    const index = phys / page.size;
    if (index >= s.total_pages) {
        panic("freePage: out of range");
    }

    if (!isUsed(s.bitmap, index)) {
        panic("freePage: double free");
    }

    setUsed(s.bitmap, index, false);
    s.owners[index] = .{ .kind = .free };
    s.free_pages += 1;
}

pub fn reservePages(phys: usize, length: usize) RangeError!void {
    return reservePagesOwned(phys, length, .{ .kind = .kernel });
}

pub fn reservePagesOwned(phys: usize, length: usize, owner: PageOwner) RangeError!void {
    if (owner.kind == .free) return error.OwnerMismatch;
    try validateRange(phys, length);
    try validateReserveOwner(phys, length, owner);
    markRangeOwned(phys, length, true, owner);
}

pub fn freePages(phys: usize, length: usize) RangeError!void {
    try validateRange(phys, length);

    const start = page.alignDown(phys);
    const end = page.alignUpChecked(try checkedRangeEnd(phys, length)) orelse return error.Overflow;
    var current = start;
    while (current < end) : (current += page.size) {
        const index = current / page.size;
        const s = state orelse return error.NotInitialized;
        if (!isUsed(s.bitmap, index)) return error.DoubleFree;
    }

    markRangeOwned(phys, length, false, .{ .kind = .free });
}

pub fn freePagesOwned(phys: usize, length: usize, expected_owner: PageOwner) RangeError!void {
    try validateRange(phys, length);

    const start = page.alignDown(phys);
    const end = page.alignUpChecked(try checkedRangeEnd(phys, length)) orelse return error.Overflow;
    var current = start;
    while (current < end) : (current += page.size) {
        const index = current / page.size;
        const s = state orelse return error.NotInitialized;
        if (!isUsed(s.bitmap, index)) return error.DoubleFree;
        if (!sameOwner(s.owners[index], expected_owner)) return error.OwnerMismatch;
    }

    markRangeOwned(phys, length, false, .{ .kind = .free });
}

pub fn pageOwner(phys: usize) ?PageOwner {
    const s = state orelse return null;
    if (!page.isAligned(phys)) return null;
    const index = phys / page.size;
    if (index >= s.total_pages) return null;
    return s.owners[index];
}

pub fn stats() ?Stats {
    const s = state orelse return null;
    var result = Stats{
        .total_pages = s.total_pages,
        .free_pages = s.free_pages,
        .used_pages = s.total_pages - s.free_pages,
        .reserved_pages = 0,
        .kernel_pages = 0,
        .heap_pages = 0,
        .page_table_pages = 0,
        .cell_pages = 0,
    };

    var index: usize = 0;
    while (index < s.total_pages) : (index += 1) {
        switch (s.owners[index].kind) {
            .free => {},
            .reserved => result.reserved_pages += 1,
            .kernel => result.kernel_pages += 1,
            .heap => result.heap_pages += 1,
            .page_table => result.page_table_pages += 1,
            .cell => result.cell_pages += 1,
        }
    }

    return result;
}

const State = struct {
    bitmap: []u8,
    owners: []PageOwner,
    total_pages: usize,
    free_pages: usize,
};

var state: ?State = null;

fn bitmapBytes(total_pages: usize) usize {
    return (total_pages + 7) / 8;
}

fn ownerBytes(total_pages: usize) ?usize {
    const bytes, const overflow = @mulWithOverflow(total_pages, @sizeOf(PageOwner));
    if (overflow != 0) return null;
    return bytes;
}

fn sameOwner(a: PageOwner, b: PageOwner) bool {
    return a.kind == b.kind and a.cell_id == b.cell_id;
}

fn bitmapLocation(page_index: usize) struct { byte: usize, mask: u8 } {
    const bit_index: u3 = @intCast(page_index % 8);
    return .{
        .byte = page_index / 8,
        .mask = @as(u8, 1) << bit_index,
    };
}

fn isUsed(bitmap: []const u8, page_index: usize) bool {
    const loc = bitmapLocation(page_index);
    return (bitmap[loc.byte] & loc.mask) != 0;
}

fn setUsed(bitmap: []u8, page_index: usize, used: bool) void {
    const loc = bitmapLocation(page_index);
    if (used) {
        bitmap[loc.byte] |= loc.mask;
    } else {
        bitmap[loc.byte] &= ~loc.mask;
    }
}

fn findHighestUsable(memory_map: *limine.MemoryMapResponse) usize {
    var highest: usize = 0;
    for (memory_map.entries()) |entry| {
        if (entry.kind != .usable) continue;
        const end: usize = @intCast(checkedMemoryMapEnd(entry));
        if (end > highest) highest = end;
    }
    return highest;
}

fn findBitmapStorage(memory_map: *limine.MemoryMapResponse, bytes: usize) ?usize {
    const needed = page.alignUpChecked(bytes) orelse return null;
    for (memory_map.entries()) |entry| {
        if (entry.kind != .usable) continue;

        const base: usize = page.alignUpChecked(@intCast(entry.base)) orelse continue;
        const end: usize = @intCast(checkedMemoryMapEnd(entry));
        const storage_end, const overflow = @addWithOverflow(base, needed);
        if (overflow == 0 and storage_end <= end) return base;
    }
    return null;
}

fn checkedMemoryMapEnd(entry: anytype) u64 {
    const end, const overflow = @addWithOverflow(entry.base, entry.length);
    if (overflow != 0) panic("pmm: memory map entry overflow");
    return end;
}

fn markPageUsed(page_index: usize, used: bool) void {
    markPageUsedOwned(page_index, used, if (used) .{ .kind = .kernel } else .{ .kind = .free });
}

fn markPageUsedOwned(page_index: usize, used: bool, owner: PageOwner) void {
    var s = &(state orelse panic("pmm not initialized"));
    const was_used = isUsed(s.bitmap, page_index);
    if (was_used == used) {
        if (used) s.owners[page_index] = owner;
        return;
    }

    setUsed(s.bitmap, page_index, used);
    s.owners[page_index] = owner;
    if (used) {
        s.free_pages -= 1;
    } else {
        s.free_pages += 1;
    }
}

fn markRange(phys: usize, length: usize, used: bool) void {
    markRangeOwned(phys, length, used, if (used) .{ .kind = .kernel } else .{ .kind = .free });
}

fn markRangeOwned(phys: usize, length: usize, used: bool, owner: PageOwner) void {
    const start = page.alignDown(phys);
    const range_end = checkedRangeEnd(phys, length) catch panic("markRange: overflow");
    const end = page.alignUpChecked(range_end) orelse panic("markRange: overflow");

    var current = start;
    while (current < end) : (current += page.size) {
        markPageUsedOwned(current / page.size, used, owner);
    }
}

fn validateRange(phys: usize, length: usize) RangeError!void {
    const s = state orelse return error.NotInitialized;
    if (length == 0) return error.EmptyRange;
    if (!page.isAligned(phys) or !page.isAligned(length)) return error.UnalignedAddress;

    const end = try checkedRangeEnd(phys, length);
    if (end / page.size > s.total_pages) return error.OutOfRange;
}

fn validateReserveOwner(phys: usize, length: usize, owner: PageOwner) RangeError!void {
    const start = page.alignDown(phys);
    const end = page.alignUpChecked(try checkedRangeEnd(phys, length)) orelse return error.Overflow;
    var current = start;
    while (current < end) : (current += page.size) {
        const index = current / page.size;
        const s = state orelse return error.NotInitialized;
        if (isUsed(s.bitmap, index) and !sameOwner(s.owners[index], owner)) {
            return error.OwnerMismatch;
        }
    }
}

fn checkedRangeEnd(phys: usize, length: usize) RangeError!usize {
    const end, const overflow = @addWithOverflow(phys, length);
    if (overflow != 0) return error.Overflow;
    return end;
}

fn markUsableMemoryFree(memory_map: *limine.MemoryMapResponse) void {
    for (memory_map.entries()) |entry| {
        if (entry.kind != .usable) continue;
        markRange(@intCast(entry.base), @intCast(entry.length), false);
    }
}

fn reserveRange(phys: usize, length: usize) void {
    markRange(phys, length, true);
}

fn reserveRangeOwned(phys: usize, length: usize, owner: PageOwner) void {
    markRangeOwned(phys, length, true, owner);
}

fn reservePage(phys: usize) void {
    reserveRange(phys, page.size);
}

fn reservePageOwned(phys: usize, owner: PageOwner) void {
    reserveRangeOwned(phys, page.size, owner);
}

test "bitmapBytes rounds page count to bytes" {
    const std = @import("std");

    try std.testing.expect(bitmapBytes(0) == 0);
    try std.testing.expect(bitmapBytes(1) == 1);
    try std.testing.expect(bitmapBytes(8) == 1);
    try std.testing.expect(bitmapBytes(9) == 2);
}

test "pmm accounting updates when ranges are marked and reserved" {
    const std = @import("std");

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    markRange(0, page.size * 2, false);
    var current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.total_pages == 8);
    try std.testing.expect(current.free_pages == 2);
    try std.testing.expect(current.used_pages == 6);

    markRange(0, page.size, false);
    current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 2);

    reservePage(0);
    current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 1);
    try std.testing.expect(current.used_pages == 7);
    try std.testing.expect(current.kernel_pages == 1);
}

test "pmm alloc and free update accounting" {
    const std = @import("std");

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    markRange(page.size, page.size, false);
    const allocated = allocPage() orelse return error.TestExpectedEqual;
    try std.testing.expect(allocated == page.size);
    var current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 0);
    try std.testing.expect(current.used_pages == 8);
    try std.testing.expect((pageOwner(allocated) orelse return error.TestExpectedEqual).kind == .kernel);

    freePage(allocated);
    current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 1);
    try std.testing.expect(current.used_pages == 7);
    try std.testing.expect((pageOwner(allocated) orelse return error.TestExpectedEqual).kind == .free);
}

test "pmm public range APIs validate inputs" {
    const std = @import("std");

    try std.testing.expectError(error.NotInitialized, reservePages(0, page.size));

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    try std.testing.expectError(error.EmptyRange, reservePages(0, 0));
    try std.testing.expectError(error.UnalignedAddress, reservePages(1, page.size));
    try std.testing.expectError(error.UnalignedAddress, reservePages(0, 1));
    try std.testing.expectError(error.OutOfRange, reservePages(page.size * 8, page.size));
    try std.testing.expectError(error.Overflow, reservePages(std.math.maxInt(usize) - page.size + 1, page.size));
}

test "pmm public range APIs reserve and free pages" {
    const std = @import("std");

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    markRange(0, page.size * 3, false);
    var current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 3);

    try reservePages(page.size, page.size);
    current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 2);
    try std.testing.expect(current.used_pages == 6);

    try freePages(page.size, page.size);
    current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.free_pages == 3);

    try std.testing.expectError(error.DoubleFree, freePages(page.size, page.size));
}

test "pmm tracks page owner classes" {
    const std = @import("std");

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    markRange(0, page.size * 4, false);
    const heap_page = allocPageOwned(.{ .kind = .heap }) orelse return error.TestExpectedEqual;
    const page_table = allocPageOwned(.{ .kind = .page_table }) orelse return error.TestExpectedEqual;
    const cell_page = allocPageOwned(PageOwner.cell(7)) orelse return error.TestExpectedEqual;

    try std.testing.expect((pageOwner(heap_page) orelse return error.TestExpectedEqual).kind == .heap);
    try std.testing.expect((pageOwner(page_table) orelse return error.TestExpectedEqual).kind == .page_table);
    const cell_owner = pageOwner(cell_page) orelse return error.TestExpectedEqual;
    try std.testing.expect(cell_owner.kind == .cell);
    try std.testing.expect(cell_owner.cell_id == 7);

    const current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.heap_pages == 1);
    try std.testing.expect(current.page_table_pages == 1);
    try std.testing.expect(current.cell_pages == 1);
}

test "pmm owner-specific free rejects mismatched owners" {
    const std = @import("std");

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    markRange(0, page.size * 2, false);
    const cell_page = allocPageOwned(PageOwner.cell(3)) orelse return error.TestExpectedEqual;

    try std.testing.expectError(
        error.OwnerMismatch,
        freePagesOwned(cell_page, page.size, PageOwner.cell(4)),
    );

    try freePagesOwned(cell_page, page.size, PageOwner.cell(3));
    try std.testing.expect((pageOwner(cell_page) orelse return error.TestExpectedEqual).kind == .free);
}

test "pmm owner-specific reserve rejects mismatched existing owners" {
    const std = @import("std");

    var bitmap = [_]u8{0xff};
    var owners = [_]PageOwner{.{}} ** 8;
    state = .{
        .bitmap = bitmap[0..],
        .owners = owners[0..],
        .total_pages = 8,
        .free_pages = 0,
    };
    defer state = null;

    markRange(0, page.size, false);
    try reservePagesOwned(0, page.size, .{ .kind = .heap });
    try reservePagesOwned(0, page.size, .{ .kind = .heap });
    try std.testing.expectError(
        error.OwnerMismatch,
        reservePagesOwned(0, page.size, .{ .kind = .kernel }),
    );
}
