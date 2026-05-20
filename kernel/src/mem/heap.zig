const builtin = @import("builtin");
const page = @import("page.zig");
const pmm = @import("pmm.zig");
const boot_info = if (builtin.is_test) test_boot_info else @import("../boot/info.zig");

const test_boot_info = struct {
    pub const BootInfo = struct {
        hhdm_offset: usize,
    };

    pub fn physToHhdm(info: *const BootInfo, phys: usize) usize {
        return info.hhdm_offset + phys;
    }
};

pub const default_bootstrap_pages: usize = 16;
pub const max_bootstrap_pages: usize = 64;

pub const HeapError = error{
    AlreadyInitialized,
    NotInitialized,
    InvalidPageCount,
    InvalidAlignment,
    EmptyAllocation,
    AllocationTooLarge,
    OutOfMemory,
};

pub const Stats = struct {
    pages: usize,
    used_bytes: usize,
    capacity_bytes: usize,
    failed_allocations: usize,
};

const State = struct {
    pages: [max_bootstrap_pages]usize = undefined,
    page_count: usize = 0,
    current_page: usize = 0,
    current_offset: usize = 0,
    used_bytes: usize = 0,
    failed_allocations: usize = 0,
};

var state: ?State = null;

pub fn init(info: *const boot_info.BootInfo, requested_pages: usize) HeapError!void {
    if (state != null) return error.AlreadyInitialized;
    if (requested_pages == 0 or requested_pages > max_bootstrap_pages) {
        return error.InvalidPageCount;
    }

    var physical_pages: [max_bootstrap_pages]usize = undefined;
    var virtual_pages: [max_bootstrap_pages]usize = undefined;
    var allocated: usize = 0;

    while (allocated < requested_pages) : (allocated += 1) {
        const phys = pmm.allocPageOwned(.{ .kind = .heap }) orelse {
            freeAllocatedPhysicalPages(physical_pages[0..allocated]);
            return error.OutOfMemory;
        };
        physical_pages[allocated] = phys;
        virtual_pages[allocated] = boot_info.physToHhdm(info, phys);
    }

    installPages(virtual_pages[0..requested_pages]);
}

pub fn alloc(size: usize, alignment: usize) HeapError![]u8 {
    var s = &(state orelse return error.NotInitialized);
    if (size == 0) return error.EmptyAllocation;
    if (size > page.size) return allocationFailed(s, error.AllocationTooLarge);
    if (!validAlignment(alignment)) return error.InvalidAlignment;

    while (s.current_page < s.page_count) {
        const base = s.pages[s.current_page];
        const start = alignForward(base + s.current_offset, alignment) orelse
            return allocationFailed(s, error.OutOfMemory);
        const offset = start - base;
        const end, const overflow = @addWithOverflow(offset, size);
        if (overflow == 0 and end <= page.size) {
            s.current_offset = end;
            s.used_bytes += size;
            const ptr: [*]u8 = @ptrFromInt(start);
            return ptr[0..size];
        }

        s.current_page += 1;
        s.current_offset = 0;
    }

    return allocationFailed(s, error.OutOfMemory);
}

pub fn stats() ?Stats {
    const s = state orelse return null;
    return .{
        .pages = s.page_count,
        .used_bytes = s.used_bytes,
        .capacity_bytes = s.page_count * page.size,
        .failed_allocations = s.failed_allocations,
    };
}

fn allocationFailed(s: *State, err: HeapError) HeapError {
    s.failed_allocations += 1;
    return err;
}

fn installPages(pages: []const usize) void {
    var next = State{};
    next.page_count = pages.len;

    var index: usize = 0;
    while (index < pages.len) : (index += 1) {
        next.pages[index] = pages[index];
    }

    state = next;
}

fn freeAllocatedPhysicalPages(pages: []const usize) void {
    for (pages) |phys| {
        pmm.freePage(phys);
    }
}

fn validAlignment(alignment: usize) bool {
    return alignment != 0 and alignment <= page.size and (alignment & (alignment - 1)) == 0;
}

fn alignForward(value: usize, alignment: usize) ?usize {
    const mask = alignment - 1;
    const added, const overflow = @addWithOverflow(value, mask);
    if (overflow != 0) return null;
    return added & ~mask;
}

fn resetForTest() void {
    state = null;
}

fn initForTest(pages: []const *[page.size]u8) HeapError!void {
    if (state != null) return error.AlreadyInitialized;
    if (pages.len == 0 or pages.len > max_bootstrap_pages) return error.InvalidPageCount;

    var bases: [max_bootstrap_pages]usize = undefined;
    var index: usize = 0;
    while (index < pages.len) : (index += 1) {
        bases[index] = @intFromPtr(pages[index]);
    }
    installPages(bases[0..pages.len]);
}

test "bootstrap heap allocates aligned slices and tracks usage" {
    const std = @import("std");

    var page0: [page.size]u8 = undefined;
    var backing = [_]*[page.size]u8{&page0};
    try initForTest(backing[0..]);
    defer resetForTest();

    const first = try alloc(16, 8);
    const second = try alloc(32, 32);

    try std.testing.expect(first.len == 16);
    try std.testing.expect(second.len == 32);
    try std.testing.expect(@intFromPtr(second.ptr) % 32 == 0);

    const current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.pages == 1);
    try std.testing.expect(current.used_bytes == 48);
    try std.testing.expect(current.capacity_bytes == page.size);
    try std.testing.expect(current.failed_allocations == 0);
}

test "bootstrap heap advances to the next page when needed" {
    const std = @import("std");

    var page0: [page.size]u8 = undefined;
    var page1: [page.size]u8 = undefined;
    var backing = [_]*[page.size]u8{ &page0, &page1 };
    try initForTest(backing[0..]);
    defer resetForTest();

    _ = try alloc(page.size - 16, 8);
    const second = try alloc(32, 16);

    try std.testing.expect(@intFromPtr(second.ptr) >= @intFromPtr(&page1));
    try std.testing.expect(@intFromPtr(second.ptr) < @intFromPtr(&page1) + page.size);
}

test "bootstrap heap reports explicit failures" {
    const std = @import("std");

    try std.testing.expectError(error.NotInitialized, alloc(1, 1));

    var page0: [page.size]u8 = undefined;
    var backing = [_]*[page.size]u8{&page0};
    try initForTest(backing[0..]);
    defer resetForTest();

    try std.testing.expectError(error.EmptyAllocation, alloc(0, 1));
    try std.testing.expectError(error.InvalidAlignment, alloc(1, 3));
    try std.testing.expectError(error.AllocationTooLarge, alloc(page.size + 1, 1));
    _ = try alloc(page.size, 1);
    try std.testing.expectError(error.OutOfMemory, alloc(1, 1));

    const current = stats() orelse return error.TestExpectedEqual;
    try std.testing.expect(current.failed_allocations == 2);
}
