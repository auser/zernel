const capability = @import("capability.zig");
const cell = @import("cell.zig");
const object = @import("object.zig");

pub const RouteId = enum(u32) { invalid = 0, _ };

pub const RouteKind = enum(u16) {
  inspect_object,
  validate_object,
  transform_object,
  render_surface,
};

pub const RouteStatus = enum(u8) {
  pending,
  accepted,
  completed,
  failed,
};

pub const RouteRequest = struct {
  id: RouteId,
  kind: RouteKind,
  status: RouteStatus,
  source_cell: cell.CellId,
  capability: capability.CapabilityId,
  input_object: object.ObjectId,
  output_object: object.ObjectId,
};

pub const max_routes = 16;

pub const CreateError = error{
    RegistryFull,
    InvalidSourceCell,
    InvalidCapability,
    InvalidInputObject,
    CapabilityTargetMismatch,
};

pub const TransitionError = error{
    InvalidRoute,
    InvalidTransition,
};

pub const Registry = struct {
    entries: [max_routes]RouteRequest = undefined,
    count: usize = 0,

    pub fn reset(self: *Registry) void {
        self.count = 0;
    }

    pub fn create(
        self: *Registry,
        cells: *const cell.Registry,
        caps: *const capability.Registry,
        objects: *const object.Registry,
        kind: RouteKind,
        source_cell: cell.CellId,
        cap: capability.CapabilityId,
        input_object: object.ObjectId,
        output_object: object.ObjectId,
    ) CreateError!RouteId {
        if (cells.get(source_cell) == null) return error.InvalidSourceCell;
        const cap_entry = caps.get(cap) orelse return error.InvalidCapability;
        if (objects.get(input_object) == null) return error.InvalidInputObject;
        if (cap_entry.target != input_object) return error.CapabilityTargetMismatch;
        if (self.count >= self.entries.len) return error.RegistryFull;

        const id: RouteId = @enumFromInt(self.count + 1);
        self.entries[self.count] = .{
            .id = id,
            .kind = kind,
            .status = .pending,
            .source_cell = source_cell,
            .capability = cap,
            .input_object = input_object,
            .output_object = output_object,
        };

        self.count += 1;
        return id;
    }

    pub fn get(self: *const Registry, id: RouteId) ?*const RouteRequest {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn transition(self: *Registry, id: RouteId, next: RouteStatus) TransitionError!void {
        const raw = @intFromEnum(id);
        if (raw == 0) return error.InvalidRoute;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return error.InvalidRoute;
        if (!isValidTransition(self.entries[index].status, next)) {
            return error.InvalidTransition;
        }

        self.entries[index].status = next;
    }

    pub fn at(self: *const Registry, index: usize) ?*const RouteRequest {
        if (index >= self.count) return null;
        return &self.entries[index];
    }
};

fn isValidTransition(from: RouteStatus, to: RouteStatus) bool {
    return switch (from) {
        .pending => to == .accepted or to == .failed,
        .accepted => to == .completed or to == .failed,
        .completed, .failed => false,
    };
}

test "route registry creates validated routes" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: cell.Registry = .{};
    var routes: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const source = try cells.create(&objects, .kernel_boot, cell_object);

    const id = try routes.create(
        &cells,
        &capabilities,
        &objects,
        .inspect_object,
        source,
        cap,
        framebuffer,
        .invalid,
    );

    try std.testing.expect(@intFromEnum(id) == 1);

    const entry = routes.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(entry.kind == .inspect_object);
    try std.testing.expect(entry.status == .pending);
    try std.testing.expect(entry.source_cell == source);
    try std.testing.expect(entry.capability == cap);
    try std.testing.expect(entry.input_object == framebuffer);
}

test "route registry rejects invalid references" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: cell.Registry = .{};
    var routes: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const memory = try objects.create(.memory_region, "memory_map");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const source = try cells.create(&objects, .kernel_boot, cell_object);

    try std.testing.expectError(
        error.InvalidSourceCell,
        routes.create(&cells, &capabilities, &objects, .inspect_object, .invalid, cap, framebuffer, .invalid),
    );
    try std.testing.expectError(
        error.InvalidCapability,
        routes.create(&cells, &capabilities, &objects, .inspect_object, source, .invalid, framebuffer, .invalid),
    );
    try std.testing.expectError(
        error.InvalidInputObject,
        routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, .invalid, .invalid),
    );
    try std.testing.expectError(
        error.CapabilityTargetMismatch,
        routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, memory, .invalid),
    );
}

test "route registry validates status transitions and exhaustion" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: cell.Registry = .{};
    var routes: Registry = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const source = try cells.create(&objects, .kernel_boot, cell_object);

    const first = try routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, framebuffer, .invalid);
    try routes.transition(first, .accepted);
    try routes.transition(first, .completed);
    try std.testing.expectError(error.InvalidTransition, routes.transition(first, .failed));

    while (routes.count < max_routes) {
        _ = try routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, framebuffer, .invalid);
    }

    try std.testing.expectError(
        error.RegistryFull,
        routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, framebuffer, .invalid),
    );
}
