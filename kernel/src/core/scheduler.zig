const cell = @import("cell.zig");

pub const ScheduleError = error{
    InvalidCell,
    CellNotRunnable,
    InvalidTransition,
};

pub const TickResult = enum(u8) {
    idle,
    charged_current,
    stale_current,
};

pub const Snapshot = struct {
    ticks: u64,
    current_cell: cell.CellId,
};

pub const Scheduler = struct {
    ticks: u64 = 0,
    current_cell: cell.CellId = .invalid,

    pub fn reset(self: *Scheduler) void {
        self.* = .{};
    }

    pub fn snapshot(self: *const Scheduler) Snapshot {
        return .{
            .ticks = self.ticks,
            .current_cell = self.current_cell,
        };
    }

    pub fn setCurrent(
        self: *Scheduler,
        cells: *cell.Registry,
        id: cell.CellId,
    ) ScheduleError!void {
        const entry = cells.get(id) orelse return error.InvalidCell;
        switch (entry.state) {
            .ready => try cells.transition(id, .running),
            .running => {},
            else => return error.CellNotRunnable,
        }
        self.current_cell = id;
    }

    pub fn clearCurrent(
        self: *Scheduler,
        cells: *cell.Registry,
        next: cell.CellState,
    ) ScheduleError!void {
        if (self.current_cell == .invalid) return;
        try cells.transition(self.current_cell, next);
        self.current_cell = .invalid;
    }

    pub fn tick(self: *Scheduler, cells: *cell.Registry) TickResult {
        self.ticks += 1;
        if (self.current_cell == .invalid) return .idle;

        const entry = cells.getMutable(self.current_cell) orelse {
            self.current_cell = .invalid;
            return .stale_current;
        };

        if (entry.state != .running) {
            self.current_cell = .invalid;
            return .stale_current;
        }

        entry.budget_ticks += 1;
        return .charged_current;
    }
};

test "scheduler names a current runnable cell" {
    const std = @import("std");
    const object = @import("object.zig");

    var objects: object.Registry = .{};
    var cells: cell.Registry = .{};
    var scheduler: Scheduler = .{};

    const cell_object = try objects.create(.execution_cell, "worker");
    const id = try cells.create(&objects, .route_worker, cell_object);
    try cells.transition(id, .ready);

    try scheduler.setCurrent(&cells, id);

    const snapshot = scheduler.snapshot();
    const entry = cells.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(snapshot.current_cell == id);
    try std.testing.expect(entry.state == .running);
}

test "scheduler tick charges the running current cell" {
    const std = @import("std");
    const object = @import("object.zig");

    var objects: object.Registry = .{};
    var cells: cell.Registry = .{};
    var scheduler: Scheduler = .{};

    const cell_object = try objects.create(.execution_cell, "worker");
    const id = try cells.create(&objects, .route_worker, cell_object);
    try cells.transition(id, .ready);
    try scheduler.setCurrent(&cells, id);

    try std.testing.expect(scheduler.tick(&cells) == .charged_current);
    try std.testing.expect(scheduler.tick(&cells) == .charged_current);

    const entry = cells.get(id) orelse return error.TestExpectedEqual;
    try std.testing.expect(scheduler.snapshot().ticks == 2);
    try std.testing.expect(entry.budget_ticks == 2);
}

test "scheduler rejects non-runnable cells" {
    const std = @import("std");
    const object = @import("object.zig");

    var objects: object.Registry = .{};
    var cells: cell.Registry = .{};
    var scheduler: Scheduler = .{};

    const cell_object = try objects.create(.execution_cell, "worker");
    const id = try cells.create(&objects, .route_worker, cell_object);

    try std.testing.expectError(error.CellNotRunnable, scheduler.setCurrent(&cells, id));
    try std.testing.expect(scheduler.tick(&cells) == .idle);
}
