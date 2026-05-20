const capability = @import("capability.zig");
const cell = @import("cell.zig");
const object = @import("object.zig");
const route = @import("route.zig");

pub const Operation = enum(u16) {
    object_created,
    capability_granted,
    capability_delegated,
    capability_revoked,
    cell_created,
    capability_attached,
    cell_transitioned,
    cell_memory_allocated,
    cell_memory_freed,
    cell_mapping_validated,
    cell_stack_allocated,
    cell_stack_freed,
    cell_address_space_created,
    cell_stack_mapped,
    scheduler_current,
    scheduler_tick,
    route_created,
    route_transitioned,
    route_denied,
};

pub const Result = enum(u8) {
    ok,
    denied,
    failed,
};

pub fn operationName(operation: Operation) []const u8 {
    return switch (operation) {
        .object_created => "object_created",
        .capability_granted => "capability_granted",
        .capability_delegated => "capability_delegated",
        .capability_revoked => "capability_revoked",
        .cell_created => "cell_created",
        .capability_attached => "capability_attached",
        .cell_transitioned => "cell_transitioned",
        .cell_memory_allocated => "cell_memory_allocated",
        .cell_memory_freed => "cell_memory_freed",
        .cell_mapping_validated => "cell_mapping_validated",
        .cell_stack_allocated => "cell_stack_allocated",
        .cell_stack_freed => "cell_stack_freed",
        .cell_address_space_created => "cell_address_space_created",
        .cell_stack_mapped => "cell_stack_mapped",
        .scheduler_current => "scheduler_current",
        .scheduler_tick => "scheduler_tick",
        .route_created => "route_created",
        .route_transitioned => "route_transitioned",
        .route_denied => "route_denied",
    };
}

pub fn resultName(result: Result) []const u8 {
    return switch (result) {
        .ok => "ok",
        .denied => "denied",
        .failed => "failed",
    };
}

pub const Record = struct {
    sequence: u64,
    operation: Operation,
    result: Result,
    object_id: object.ObjectId,
    source_cell: cell.CellId,
    capability_id: capability.CapabilityId,
    route_id: route.RouteId,
};

pub const max_records = 64;

pub const RecordError = error{
    RegistryFull,
};

pub const Registry = struct {
    entries: [max_records]Record = undefined,
    count: usize = 0,
    next_sequence: u64 = 1,

    pub fn reset(self: *Registry) void {
        self.count = 0;
        self.next_sequence = 1;
    }

    pub fn record(
        self: *Registry,
        operation: Operation,
        result: Result,
        object_id: object.ObjectId,
        source_cell: cell.CellId,
        capability_id: capability.CapabilityId,
        route_id: route.RouteId,
    ) RecordError!void {
        if (self.count >= self.entries.len) return error.RegistryFull;

        self.entries[self.count] = .{
            .sequence = self.next_sequence,
            .operation = operation,
            .result = result,
            .object_id = object_id,
            .source_cell = source_cell,
            .capability_id = capability_id,
            .route_id = route_id,
        };

        self.count += 1;
        self.next_sequence += 1;
    }

    pub fn at(self: *const Registry, index: usize) ?*const Record {
        if (index >= self.count) return null;
        return &self.entries[index];
    }
};

test "provenance registry records monotonically sequenced events" {
    const std = @import("std");

    var registry: Registry = .{};
    const target: object.ObjectId = @enumFromInt(1);
    const cap: capability.CapabilityId = @enumFromInt(1);

    try registry.record(.object_created, .ok, target, .invalid, .invalid, .invalid);
    try registry.record(.capability_granted, .ok, target, .invalid, cap, .invalid);

    const first = registry.at(0) orelse return error.TestExpectedEqual;
    const second = registry.at(1) orelse return error.TestExpectedEqual;

    try std.testing.expect(first.sequence == 1);
    try std.testing.expect(second.sequence == 2);
    try std.testing.expect(second.object_id == target);
    try std.testing.expect(second.capability_id == cap);
}

test "provenance registry reports exhaustion" {
    const std = @import("std");

    var registry: Registry = .{};
    var index: usize = 0;
    while (index < max_records) : (index += 1) {
        try registry.record(.object_created, .ok, .invalid, .invalid, .invalid, .invalid);
    }

    try std.testing.expectError(
        error.RegistryFull,
        registry.record(.object_created, .ok, .invalid, .invalid, .invalid, .invalid),
    );
}

test "provenance names are stable strings" {
    const std = @import("std");

    try std.testing.expectEqualStrings("capability_delegated", operationName(.capability_delegated));
    try std.testing.expectEqualStrings("capability_revoked", operationName(.capability_revoked));
    try std.testing.expectEqualStrings("cell_memory_allocated", operationName(.cell_memory_allocated));
    try std.testing.expectEqualStrings("cell_memory_freed", operationName(.cell_memory_freed));
    try std.testing.expectEqualStrings("cell_mapping_validated", operationName(.cell_mapping_validated));
    try std.testing.expectEqualStrings("cell_stack_allocated", operationName(.cell_stack_allocated));
    try std.testing.expectEqualStrings("cell_stack_freed", operationName(.cell_stack_freed));
    try std.testing.expectEqualStrings("cell_address_space_created", operationName(.cell_address_space_created));
    try std.testing.expectEqualStrings("cell_stack_mapped", operationName(.cell_stack_mapped));
    try std.testing.expectEqualStrings("scheduler_current", operationName(.scheduler_current));
    try std.testing.expectEqualStrings("scheduler_tick", operationName(.scheduler_tick));
    try std.testing.expectEqualStrings("route_denied", operationName(.route_denied));
    try std.testing.expectEqualStrings("denied", resultName(.denied));
}
