const cell = @import("cell.zig");
const page = @import("../mem/page.zig");
const virtual = @import("../mem/virtual.zig");

pub const StackId = enum(u32) { invalid = 0, _ };

pub const max_stacks = 16;
pub const max_stack_pages = 16;
pub const default_stack_pages = 4;
pub const guard_pages_per_stack = 2;
pub const virtual_arena_base: usize = 0x0000_6000_0000_0000;
pub const virtual_slot_pages = max_stack_pages + guard_pages_per_stack;
pub const virtual_slot_size = virtual_slot_pages * page.size;

pub const Stack = struct {
    id: StackId,
    owner: cell.CellId,
    active: bool = true,
    virtual_base: usize,
    pages: [max_stack_pages]usize = [_]usize{0} ** max_stack_pages,
    page_count: usize = 0,
    low_guard_pages: usize = 1,
    high_guard_pages: usize = 1,

    pub fn totalVirtualPages(self: *const Stack) usize {
        return self.low_guard_pages + self.page_count + self.high_guard_pages;
    }

    pub fn layout(self: *const Stack) virtual.LayoutError!virtual.StackLayout {
        return virtual.StackLayout.init(
            self.virtual_base,
            self.page_count,
            self.low_guard_pages,
            self.high_guard_pages,
        );
    }
};

pub const CreateError = error{
    RegistryFull,
    InvalidCell,
    InvalidPageCount,
    OutOfMemory,
};

pub const DestroyError = error{
    InvalidStack,
    InvalidCell,
    StackOwnerMismatch,
};

pub const Registry = struct {
    entries: [max_stacks]Stack = undefined,
    count: usize = 0,

    pub fn reset(self: *Registry) void {
        self.count = 0;
    }

    pub fn reserve(self: *Registry, owner: cell.CellId, page_count: usize) CreateError!*Stack {
        if (owner == .invalid) return error.InvalidCell;
        if (page_count == 0 or page_count > max_stack_pages) return error.InvalidPageCount;

        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            if (!self.entries[index].active) {
                self.entries[index] = .{
                    .id = @enumFromInt(index + 1),
                    .owner = owner,
                    .virtual_base = virtualBaseForSlot(index),
                    .page_count = page_count,
                };
                return &self.entries[index];
            }
        }

        if (self.count >= self.entries.len) return error.RegistryFull;

        self.entries[self.count] = .{
            .id = @enumFromInt(self.count + 1),
            .owner = owner,
            .virtual_base = virtualBaseForSlot(self.count),
            .page_count = page_count,
        };
        self.count += 1;
        return &self.entries[self.count - 1];
    }

    pub fn get(self: *const Registry, id: StackId) ?*const Stack {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        if (!self.entries[index].active) return null;
        return &self.entries[index];
    }

    pub fn getMutable(self: *Registry, id: StackId) ?*Stack {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        if (!self.entries[index].active) return null;
        return &self.entries[index];
    }

    pub fn release(self: *Registry, id: StackId, owner: cell.CellId) DestroyError!void {
        if (owner == .invalid) return error.InvalidCell;
        const entry = self.getMutable(id) orelse return error.InvalidStack;
        if (entry.owner != owner) return error.StackOwnerMismatch;

        entry.active = false;
        entry.pages = [_]usize{0} ** max_stack_pages;
        entry.page_count = 0;
    }
};

pub fn virtualBaseForSlot(index: usize) usize {
    return virtual_arena_base + index * virtual_slot_size;
}

test "stack registry reserves stack metadata with guard pages" {
    const std = @import("std");

    var registry: Registry = .{};
    const owner: cell.CellId = @enumFromInt(1);
    const entry = try registry.reserve(owner, 2);

    try std.testing.expect(entry.id == @as(StackId, @enumFromInt(1)));
    try std.testing.expect(entry.owner == owner);
    try std.testing.expect(entry.active);
    try std.testing.expect(entry.page_count == 2);
    try std.testing.expect(entry.low_guard_pages == 1);
    try std.testing.expect(entry.high_guard_pages == 1);
    try std.testing.expect(entry.totalVirtualPages() == 4);
    try std.testing.expect(entry.virtual_base == virtual_arena_base);
}

test "stack registry validates owner and size" {
    const std = @import("std");

    var registry: Registry = .{};

    try std.testing.expectError(error.InvalidCell, registry.reserve(.invalid, 1));
    try std.testing.expectError(error.InvalidPageCount, registry.reserve(@enumFromInt(1), 0));
    try std.testing.expectError(error.InvalidPageCount, registry.reserve(@enumFromInt(1), max_stack_pages + 1));
}

test "stack registry releases and reuses stack slots" {
    const std = @import("std");

    var registry: Registry = .{};
    const owner: cell.CellId = @enumFromInt(1);
    const first = try registry.reserve(owner, 2);
    const first_id = first.id;

    try registry.release(first_id, owner);
    try std.testing.expect(registry.get(first_id) == null);

    const second = try registry.reserve(owner, 1);
    try std.testing.expect(second.id == first_id);
    try std.testing.expect(second.page_count == 1);
    try std.testing.expect(second.virtual_base == virtual_arena_base);
}

test "stack registry exposes a guard-aware virtual layout" {
    const std = @import("std");

    var registry: Registry = .{};
    const entry = try registry.reserve(@enumFromInt(1), 2);
    const layout = try entry.layout();

    try std.testing.expect(layout.classify(entry.virtual_base) == .low_guard);
    try std.testing.expect(layout.classify(entry.virtual_base + page.size) == .mapped);
    try std.testing.expect(layout.classify(entry.virtual_base + page.size * 3) == .high_guard);
    try std.testing.expectError(error.GuardPage, layout.validateMappedAddress(entry.virtual_base));
}
