const cell = @import("cell.zig");
const route = @import("route.zig");

pub const Decision = enum(u8) {
    accept,
    deny,
    defer_route,
};

pub const Reason = enum(u8) {
    none,
    invalid_source_cell,
    route_not_pending,
};

pub const Result = struct {
    decision: Decision,
    reason: Reason = .none,
};

pub const Policy = struct {
    pub fn evaluate(
        _: Policy,
        cells: *const cell.Registry,
        request: *const route.RouteRequest,
    ) Result {
        if (request.status != .pending) {
            return .{ .decision = .defer_route, .reason = .route_not_pending };
        }
        if (cells.get(request.source_cell) == null) {
            return .{ .decision = .deny, .reason = .invalid_source_cell };
        }
        return .{ .decision = .accept };
    }
};

test "default policy accepts pending routes from valid source cells" {
    const std = @import("std");
    const object = @import("object.zig");
    const capability = @import("capability.zig");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: cell.Registry = .{};
    var routes: route.Registry = .{};
    const policy: Policy = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const source = try cells.create(&objects, .kernel_boot, cell_object);
    try cells.grantCapability(&capabilities, source, cap);

    const route_id = try routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, framebuffer, .invalid);
    const request = routes.get(route_id) orelse return error.TestExpectedEqual;
    const result = policy.evaluate(&cells, request);

    try std.testing.expect(result.decision == .accept);
    try std.testing.expect(result.reason == .none);
}

test "default policy defers non-pending routes" {
    const std = @import("std");
    const object = @import("object.zig");
    const capability = @import("capability.zig");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: cell.Registry = .{};
    var routes: route.Registry = .{};
    const policy: Policy = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const source = try cells.create(&objects, .kernel_boot, cell_object);
    try cells.grantCapability(&capabilities, source, cap);

    const route_id = try routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, framebuffer, .invalid);
    try routes.transition(route_id, .accepted);
    const request = routes.get(route_id) orelse return error.TestExpectedEqual;
    const result = policy.evaluate(&cells, request);

    try std.testing.expect(result.decision == .defer_route);
    try std.testing.expect(result.reason == .route_not_pending);
}
