const capability = @import("capability.zig");
const object = @import("object.zig");

pub const CellId = enum(u32) { invalid = 0, _ };

pub const CellKind = enum(u16) {
    kernel_boot,
    shell_command,
    driver_service,
    route_worker,
    agent_loop,
};

pub const CellState = enum(u8) {
    created,
    ready,
    running,
    blocked,
    completed,
    failed,
};

pub const max_cells = 16;
pub const max_cell_capabilities = 4;

pub const CapabilitySlot = struct {
    id: capability.CapabilityId = .invalid,
    generation: u32 = 0,
};

pub const ExecutionCell = struct {
    id: CellId,
    kind: CellKind,
    state: CellState,
    object_id: object.ObjectId,
    capabilities: [max_cell_capabilities]CapabilitySlot,
    capability_count: usize = 0,
    budget_ticks: usize,
    memory_pages: usize,
};

pub const CreateError = error{
    RegistryFull,
    InvalidObject,
};

pub const TransitionError = error{
    InvalidCell,
    InvalidTransition,
};

pub const GrantError = error{
    InvalidCell,
    InvalidCapability,
    CapabilityListFull,
};

pub const DelegateError = error{
    InvalidSourceCell,
    InvalidTargetCell,
    InvalidCapability,
    SourceCellDoesNotOwnCapability,
    CapabilityListFull,
    RegistryFull,
    DelegateRightRequired,
    RightsEscalation,
};

pub const MemoryError = error{
    InvalidCell,
    Underflow,
};

pub const Registry = struct {
    entries: [max_cells]ExecutionCell = undefined,
    count: usize = 0,

    pub fn reset(self: *Registry) void {
        self.count = 0;
    }

    pub fn create(
        self: *Registry,
        objects: *const object.Registry,
        kind: CellKind,
        object_id: object.ObjectId,
    ) CreateError!CellId {
        if (objects.get(object_id) == null) return error.InvalidObject;
        if (self.count >= self.entries.len) return error.RegistryFull;

        const id: CellId = @enumFromInt(self.count + 1);
        self.entries[self.count] = .{
            .id = id,
            .kind = kind,
            .state = .created,
            .object_id = object_id,
            .capabilities = [_]CapabilitySlot{.{}} ** max_cell_capabilities,
            .budget_ticks = 0,
            .memory_pages = 0,
        };

        self.count += 1;
        return id;
    }

    pub fn get(self: *const Registry, id: CellId) ?*const ExecutionCell {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn getMutable(self: *Registry, id: CellId) ?*ExecutionCell {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn transition(self: *Registry, id: CellId, next: CellState) TransitionError!void {
        const entry = self.getMutable(id) orelse return error.InvalidCell;
        if (!isValidTransition(entry.state, next)) return error.InvalidTransition;
        entry.state = next;
    }

    pub fn grantCapability(
        self: *Registry,
        caps: *const capability.Registry,
        id: CellId,
        cap: capability.CapabilityId,
    ) GrantError!void {
        const entry = self.getMutable(id) orelse return error.InvalidCell;
        const cap_entry = caps.getActive(cap) orelse return error.InvalidCapability;
        if (entry.capability_count >= entry.capabilities.len) return error.CapabilityListFull;

        entry.capabilities[entry.capability_count] = .{
            .id = cap,
            .generation = cap_entry.generation,
        };
        entry.capability_count += 1;
    }

    pub fn ownsCapability(
        self: *const Registry,
        caps: *const capability.Registry,
        id: CellId,
        cap: capability.CapabilityId,
    ) bool {
        const entry = self.get(id) orelse return false;

        var index: usize = 0;
        while (index < entry.capability_count) : (index += 1) {
            const slot = entry.capabilities[index];
            if (slot.id == cap and caps.isActiveGeneration(slot.id, slot.generation)) return true;
        }

        return false;
    }

    pub fn delegateCapability(
        self: *Registry,
        caps: *capability.Registry,
        source_cell: CellId,
        target_cell: CellId,
        source_cap: capability.CapabilityId,
        rights: capability.CapabilityRights,
    ) DelegateError!capability.CapabilityId {
        if (self.get(source_cell) == null) return error.InvalidSourceCell;
        if (!self.ownsCapability(caps, source_cell, source_cap)) {
            return error.SourceCellDoesNotOwnCapability;
        }

        const target = self.getMutable(target_cell) orelse return error.InvalidTargetCell;
        if (target.capability_count >= target.capabilities.len) return error.CapabilityListFull;

        const child = try caps.delegate(source_cap, rights);
        const child_entry = caps.getActive(child) orelse return error.InvalidCapability;
        target.capabilities[target.capability_count] = .{
            .id = child,
            .generation = child_entry.generation,
        };
        target.capability_count += 1;
        return child;
    }

    pub fn at(self: *const Registry, index: usize) ?*const ExecutionCell {
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn chargeMemoryPages(self: *Registry, id: CellId, count: usize) MemoryError!void {
        const entry = self.getMutable(id) orelse return error.InvalidCell;
        entry.memory_pages += count;
    }

    pub fn releaseMemoryPages(self: *Registry, id: CellId, count: usize) MemoryError!void {
        const entry = self.getMutable(id) orelse return error.InvalidCell;
        if (entry.memory_pages < count) return error.Underflow;
        entry.memory_pages -= count;
    }
};

fn isValidTransition(from: CellState, to: CellState) bool {
    return switch (from) {
        .created => to == .ready,
        .ready => to == .running,
        .running => to == .blocked or to == .completed or to == .failed,
        .blocked => to == .ready,
        .completed, .failed => false,
    };
}

test "cell registry creates cells backed by objects" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var cells: Registry = .{};

    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const id = try cells.create(&objects, .kernel_boot, cell_object);

    try std.testing.expect(@intFromEnum(id) == 1);

    const entry = cells.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(entry.kind == .kernel_boot);
    try std.testing.expect(entry.state == .created);
    try std.testing.expect(entry.object_id == cell_object);
    try std.testing.expect(entry.capability_count == 0);
    try std.testing.expect(entry.memory_pages == 0);
}

test "cell registry rejects invalid backing objects and exhaustion" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var cells: Registry = .{};

    try std.testing.expectError(
        error.InvalidObject,
        cells.create(&objects, .kernel_boot, .invalid),
    );

    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    var index: usize = 0;
    while (index < max_cells) : (index += 1) {
        _ = try cells.create(&objects, .kernel_boot, cell_object);
    }

    try std.testing.expectError(
        error.RegistryFull,
        cells.create(&objects, .kernel_boot, cell_object),
    );
}

test "cell registry validates lifecycle transitions" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var cells: Registry = .{};

    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const id = try cells.create(&objects, .kernel_boot, cell_object);

    try cells.transition(id, .ready);
    try cells.transition(id, .running);
    try std.testing.expectError(error.InvalidTransition, cells.transition(id, .ready));
    try cells.transition(id, .completed);
    try std.testing.expectError(error.InvalidTransition, cells.transition(id, .running));
}

test "cell registry grants valid capabilities" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const id = try cells.create(&objects, .kernel_boot, cell_object);

    try cells.grantCapability(&capabilities, id, cap);

    const entry = cells.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(entry.capability_count == 1);
    try std.testing.expect(entry.capabilities[0].id == cap);
    try std.testing.expectError(
        error.InvalidCapability,
        cells.grantCapability(&capabilities, id, .invalid),
    );
}

test "cell registry reports capability ownership" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const id = try cells.create(&objects, .kernel_boot, cell_object);

    try std.testing.expect(!cells.ownsCapability(&capabilities, id, cap));
    try cells.grantCapability(&capabilities, id, cap);
    try std.testing.expect(cells.ownsCapability(&capabilities, id, cap));
    try std.testing.expect(!cells.ownsCapability(&capabilities, .invalid, cap));
}

test "cell capability ownership rejects revoked stale generations" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const id = try cells.create(&objects, .kernel_boot, cell_object);

    try cells.grantCapability(&capabilities, id, cap);
    try std.testing.expect(cells.ownsCapability(&capabilities, id, cap));

    try capabilities.revoke(cap);
    try std.testing.expect(!cells.ownsCapability(&capabilities, id, cap));
    try std.testing.expectError(error.InvalidCapability, cells.grantCapability(&capabilities, id, cap));
}

test "cell registry delegates capabilities between cells" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const source_cap = try capabilities.grant(
        &objects,
        framebuffer,
        .{ .read = true, .write = true, .delegate = true },
    );
    const source_object = try objects.create(.execution_cell, "source");
    const target_object = try objects.create(.execution_cell, "target");
    const source = try cells.create(&objects, .kernel_boot, source_object);
    const target = try cells.create(&objects, .route_worker, target_object);

    try cells.grantCapability(&capabilities, source, source_cap);
    const child = try cells.delegateCapability(
        &capabilities,
        source,
        target,
        source_cap,
        .{ .read = true },
    );

    try std.testing.expect(!cells.ownsCapability(&capabilities, source, child));
    try std.testing.expect(cells.ownsCapability(&capabilities, target, child));

    const child_entry = capabilities.getActive(child) orelse return error.TestExpectedEqual;
    try std.testing.expect(child_entry.target == framebuffer);
    try std.testing.expect(child_entry.rights.read);
    try std.testing.expect(!child_entry.rights.write);
}

test "cell registry rejects unauthorized capability delegation" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const no_delegate = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const source_object = try objects.create(.execution_cell, "source");
    const target_object = try objects.create(.execution_cell, "target");
    const source = try cells.create(&objects, .kernel_boot, source_object);
    const target = try cells.create(&objects, .route_worker, target_object);

    try std.testing.expectError(
        error.SourceCellDoesNotOwnCapability,
        cells.delegateCapability(&capabilities, source, target, no_delegate, .{ .read = true }),
    );

    try cells.grantCapability(&capabilities, source, no_delegate);
    try std.testing.expectError(
        error.DelegateRightRequired,
        cells.delegateCapability(&capabilities, source, target, no_delegate, .{ .read = true }),
    );
}

test "cell registry accounts memory pages" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var cells: Registry = .{};

    const cell_object = try objects.create(.execution_cell, "worker");
    const id = try cells.create(&objects, .route_worker, cell_object);

    try cells.chargeMemoryPages(id, 2);
    var entry = cells.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(entry.memory_pages == 2);

    try cells.releaseMemoryPages(id, 1);
    entry = cells.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(entry.memory_pages == 1);

    try std.testing.expectError(error.Underflow, cells.releaseMemoryPages(id, 2));
    try std.testing.expectError(error.InvalidCell, cells.chargeMemoryPages(.invalid, 1));
}
