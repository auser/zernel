const pmm = @import("pmm.zig");

pub const PermissionError = error{
    WritableExecutable,
};

pub const CellMappingError = PermissionError || error{
    PageNotOwnedByCell,
};

pub const Permissions = struct {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
    user: bool = false,

    pub fn validateKernelMapping(self: Permissions) PermissionError!void {
        if (self.write and self.execute) return error.WritableExecutable;
    }
};

pub fn validateCellPageMapping(
    cell_id: u32,
    owner: pmm.PageOwner,
    permissions: Permissions,
) CellMappingError!void {
    try permissions.validateKernelMapping();
    if (owner.kind != .cell or owner.cell_id != cell_id) return error.PageNotOwnedByCell;
}

test "kernel mappings reject writable executable permissions" {
    const std = @import("std");

    try (Permissions{ .read = true, .write = false, .execute = true }).validateKernelMapping();
    try (Permissions{ .read = true, .write = true, .execute = false }).validateKernelMapping();
    try std.testing.expectError(
        error.WritableExecutable,
        (Permissions{ .read = true, .write = true, .execute = true }).validateKernelMapping(),
    );
}

test "cell mappings require matching page ownership" {
    const std = @import("std");

    try validateCellPageMapping(
        7,
        pmm.PageOwner.cell(7),
        .{ .read = true, .write = true, .execute = false, .user = true },
    );
    try std.testing.expectError(
        error.PageNotOwnedByCell,
        validateCellPageMapping(7, pmm.PageOwner.cell(8), .{}),
    );
    try std.testing.expectError(
        error.PageNotOwnedByCell,
        validateCellPageMapping(7, .{ .kind = .kernel }, .{}),
    );
    try std.testing.expectError(
        error.WritableExecutable,
        validateCellPageMapping(7, pmm.PageOwner.cell(7), .{ .write = true, .execute = true }),
    );
}
