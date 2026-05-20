const cell = @import("cell.zig");
const stack = @import("stack.zig");
const virtual = @import("../mem/virtual.zig");

pub const AddressSpaceId = enum(u32) { invalid = 0, _ };

pub const max_address_spaces = cell.max_cells;
pub const max_stack_mappings = stack.max_stacks;

pub const StackMapping = struct {
    stack_id: stack.StackId = .invalid,
    layout: virtual.StackLayout,
    mapped: bool = false,
};

pub const AddressSpace = struct {
    id: AddressSpaceId,
    owner: cell.CellId,
    stacks: [max_stack_mappings]StackMapping = undefined,
    stack_count: usize = 0,
};

pub const CreateError = error{
    InvalidCell,
    RegistryFull,
};

pub const MapError = virtual.LayoutError || error{
    InvalidAddressSpace,
    InvalidCell,
    InvalidStack,
    StackOwnerMismatch,
    StackAlreadyAttached,
    StackListFull,
    StackMapped,
};

pub const Registry = struct {
    entries: [max_address_spaces]AddressSpace = undefined,
    count: usize = 0,

    pub fn reset(self: *Registry) void {
        self.count = 0;
    }

    pub fn ensureForCell(self: *Registry, owner: cell.CellId) CreateError!*AddressSpace {
        if (owner == .invalid) return error.InvalidCell;
        if (self.getForCellMutable(owner)) |existing| return existing;

        if (self.count >= self.entries.len) return error.RegistryFull;

        self.entries[self.count] = .{
            .id = @enumFromInt(self.count + 1),
            .owner = owner,
        };
        self.count += 1;
        return &self.entries[self.count - 1];
    }

    pub fn getForCell(self: *const Registry, owner: cell.CellId) ?*const AddressSpace {
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            if (self.entries[index].owner == owner) return &self.entries[index];
        }
        return null;
    }

    pub fn getForCellMutable(self: *Registry, owner: cell.CellId) ?*AddressSpace {
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            if (self.entries[index].owner == owner) return &self.entries[index];
        }
        return null;
    }

    pub fn attachStack(
        self: *Registry,
        owner: cell.CellId,
        stack_entry: *const stack.Stack,
    ) MapError!*StackMapping {
        if (owner == .invalid) return error.InvalidCell;
        if (stack_entry.owner != owner) return error.StackOwnerMismatch;

        const space = self.ensureForCell(owner) catch |err| {
            return switch (err) {
                error.InvalidCell => error.InvalidCell,
                error.RegistryFull => error.InvalidAddressSpace,
            };
        };

        var index: usize = 0;
        while (index < space.stack_count) : (index += 1) {
            if (space.stacks[index].stack_id == stack_entry.id) return error.StackAlreadyAttached;
        }

        if (space.stack_count >= space.stacks.len) return error.StackListFull;

        const layout = try stack_entry.layout();
        space.stacks[space.stack_count] = .{
            .stack_id = stack_entry.id,
            .layout = layout,
            .mapped = false,
        };
        space.stack_count += 1;
        return &space.stacks[space.stack_count - 1];
    }

    pub fn markStackMapped(
        self: *Registry,
        owner: cell.CellId,
        stack_id: stack.StackId,
    ) MapError!void {
        const mapping = self.getStackMappingMutable(owner, stack_id) orelse return error.InvalidStack;
        mapping.mapped = true;
    }

    pub fn detachStack(
        self: *Registry,
        owner: cell.CellId,
        stack_id: stack.StackId,
    ) MapError!void {
        const space = self.getForCellMutable(owner) orelse return error.InvalidAddressSpace;

        var index: usize = 0;
        while (index < space.stack_count) : (index += 1) {
            if (space.stacks[index].stack_id != stack_id) continue;
            if (space.stacks[index].mapped) return error.StackMapped;

            var shift = index;
            while (shift + 1 < space.stack_count) : (shift += 1) {
                space.stacks[shift] = space.stacks[shift + 1];
            }
            space.stack_count -= 1;
            return;
        }

        return error.InvalidStack;
    }

    pub fn getStackMapping(
        self: *const Registry,
        owner: cell.CellId,
        stack_id: stack.StackId,
    ) ?*const StackMapping {
        const space = self.getForCell(owner) orelse return null;
        var index: usize = 0;
        while (index < space.stack_count) : (index += 1) {
            if (space.stacks[index].stack_id == stack_id) return &space.stacks[index];
        }
        return null;
    }

    fn getStackMappingMutable(
        self: *Registry,
        owner: cell.CellId,
        stack_id: stack.StackId,
    ) ?*StackMapping {
        const space = self.getForCellMutable(owner) orelse return null;
        var index: usize = 0;
        while (index < space.stack_count) : (index += 1) {
            if (space.stacks[index].stack_id == stack_id) return &space.stacks[index];
        }
        return null;
    }
};

test "address space registry creates one address space per cell" {
    const std = @import("std");

    var registry: Registry = .{};
    const owner: cell.CellId = @enumFromInt(1);

    const first = try registry.ensureForCell(owner);
    const second = try registry.ensureForCell(owner);

    try std.testing.expect(first.id == second.id);
    try std.testing.expect(registry.count == 1);
    try std.testing.expect(first.owner == owner);
}

test "address space registry attaches stack layouts" {
    const std = @import("std");

    var registry: Registry = .{};
    var stacks: stack.Registry = .{};
    const owner: cell.CellId = @enumFromInt(1);
    const stack_entry = try stacks.reserve(owner, 2);

    const mapping = try registry.attachStack(owner, stack_entry);

    try std.testing.expect(mapping.stack_id == stack_entry.id);
    try std.testing.expect(mapping.layout.mapped_pages == 2);
    try std.testing.expect(!mapping.mapped);
    try std.testing.expectError(error.StackAlreadyAttached, registry.attachStack(owner, stack_entry));

    try registry.markStackMapped(owner, stack_entry.id);
    try std.testing.expect((registry.getStackMapping(owner, stack_entry.id) orelse return error.TestExpectedEqual).mapped);
}

test "address space registry detaches only unmapped stacks" {
    const std = @import("std");

    var registry: Registry = .{};
    var stacks: stack.Registry = .{};
    const owner: cell.CellId = @enumFromInt(1);
    const first = try stacks.reserve(owner, 1);
    const second = try stacks.reserve(owner, 1);

    _ = try registry.attachStack(owner, first);
    _ = try registry.attachStack(owner, second);
    try registry.markStackMapped(owner, second.id);

    try registry.detachStack(owner, first.id);
    try std.testing.expect(registry.getStackMapping(owner, first.id) == null);
    try std.testing.expectError(error.StackMapped, registry.detachStack(owner, second.id));
}

test "address space registry rejects stack owner mismatch" {
    const std = @import("std");

    var registry: Registry = .{};
    var stacks: stack.Registry = .{};
    const stack_entry = try stacks.reserve(@enumFromInt(1), 2);

    try std.testing.expectError(error.StackOwnerMismatch, registry.attachStack(@enumFromInt(2), stack_entry));
}
