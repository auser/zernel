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

pub const ExecutionCell = struct {
    id: CellId,
    kind: CellKind,
    state: CellState,
    object_id: object.ObjectId,
    capabilities: [max_cell_capabilities]capability.CapabilityId,
    capability_count: usize = 0,
    budget_ticks: usize,
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
            .capabilities = [_]capability.CapabilityId{.invalid} ** max_cell_capabilities,
            .budget_ticks = 0,
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
        if (caps.get(cap) == null) return error.InvalidCapability;
        if (entry.capability_count >= entry.capabilities.len) return error.CapabilityListFull;

        entry.capabilities[entry.capability_count] = cap;
        entry.capability_count += 1;
    }

    pub fn at(self: *const Registry, index: usize) ?*const ExecutionCell {
        if (index >= self.count) return null;
        return &self.entries[index];
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
    try std.testing.expect(entry.capabilities[0] == cap);
    try std.testing.expectError(
        error.InvalidCapability,
        cells.grantCapability(&capabilities, id, .invalid),
    );
}
