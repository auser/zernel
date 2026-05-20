const cell = @import("cell.zig");
const policy = @import("policy.zig");
const route = @import("route.zig");

pub const DispatchStatus = enum(u8) {
    idle,
    accepted,
    denied,
    deferred,
};

pub const DispatchResult = struct {
    status: DispatchStatus,
    route_id: route.RouteId = .invalid,
    policy_reason: policy.Reason = .none,
};

pub const DispatchError = error{
    InvalidRoute,
    InvalidTransition,
};

pub const Dispatcher = struct {
    route_policy: policy.Policy = .{},

    pub fn dispatchNext(
        self: Dispatcher,
        routes: *route.Registry,
        cells: *const cell.Registry,
    ) DispatchError!DispatchResult {
        const route_id = routes.firstPending() orelse return .{ .status = .idle };
        const request = routes.get(route_id) orelse return error.InvalidRoute;
        const decision = self.route_policy.evaluate(cells, request);

        switch (decision.decision) {
            .accept => {
                try routes.transition(route_id, .accepted);
                return .{ .status = .accepted, .route_id = route_id };
            },
            .deny => {
                try routes.transition(route_id, .failed);
                return .{
                    .status = .denied,
                    .route_id = route_id,
                    .policy_reason = decision.reason,
                };
            },
            .defer_route => return .{
                .status = .deferred,
                .route_id = route_id,
                .policy_reason = decision.reason,
            },
        }
    }
};

test "dispatcher accepts the first pending route" {
    const std = @import("std");
    const object = @import("object.zig");
    const capability = @import("capability.zig");

    var objects: object.Registry = .{};
    var capabilities: capability.Registry = .{};
    var cells: cell.Registry = .{};
    var routes: route.Registry = .{};
    const dispatcher: Dispatcher = .{};

    const framebuffer = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, framebuffer, .{ .read = true });
    const cell_object = try objects.create(.execution_cell, "kernel_boot");
    const source = try cells.create(&objects, .kernel_boot, cell_object);
    try cells.grantCapability(&capabilities, source, cap);

    const route_id = try routes.create(&cells, &capabilities, &objects, .inspect_object, source, cap, framebuffer, .invalid);
    const result = try dispatcher.dispatchNext(&routes, &cells);

    try std.testing.expect(result.status == .accepted);
    try std.testing.expect(result.route_id == route_id);

    const request = routes.get(route_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(request.status == .accepted);
}

test "dispatcher idles with no pending routes" {
    const std = @import("std");

    var cells: cell.Registry = .{};
    var routes: route.Registry = .{};
    const dispatcher: Dispatcher = .{};

    const result = try dispatcher.dispatchNext(&routes, &cells);
    try std.testing.expect(result.status == .idle);
    try std.testing.expect(result.route_id == .invalid);
}
