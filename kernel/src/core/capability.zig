const object = @import("object.zig");

pub const CapabilityId = enum(u32) { invalid = 0, _ };

pub const CapabilityRights = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    delegate: bool = false,
    reserved: u28 = 0,

    pub fn contains(self: CapabilityRights, required: CapabilityRights) bool {
        return (!required.read or self.read) and
            (!required.write or self.write) and
            (!required.execute or self.execute) and
            (!required.delegate or self.delegate);
    }
};

pub const Capability = struct {
    id: CapabilityId,
    target: object.ObjectId,
    rights: CapabilityRights,
    generation: u32,
    revoked: bool = false,
};

pub const max_capabilities = 32;

pub const GrantError = error{
    RegistryFull,
    InvalidTarget,
};

pub const RevokeError = error{
    InvalidCapability,
    AlreadyRevoked,
};

pub const DelegateError = error{
    RegistryFull,
    InvalidCapability,
    DelegateRightRequired,
    RightsEscalation,
};

pub const Registry = struct {
    entries: [max_capabilities]Capability = undefined,
    count: usize = 0,
    next_generation: u32 = 1,

    pub fn reset(self: *Registry) void {
        self.count = 0;
        self.next_generation = 1;
    }

    pub fn grant(
        self: *Registry,
        objects: *const object.Registry,
        target: object.ObjectId,
        rights: CapabilityRights,
    ) GrantError!CapabilityId {
        if (objects.get(target) == null) return error.InvalidTarget;
        if (self.count >= self.entries.len) return error.RegistryFull;

        const id: CapabilityId = @enumFromInt(self.count + 1);
        self.entries[self.count] = .{
            .id = id,
            .target = target,
            .rights = rights,
            .generation = self.next_generation,
            .revoked = false,
        };

        self.count += 1;
        self.next_generation += 1;
        return id;
    }

    pub fn get(self: *const Registry, id: CapabilityId) ?*const Capability {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn getActive(self: *const Registry, id: CapabilityId) ?*const Capability {
        const entry = self.get(id) orelse return null;
        if (entry.revoked) return null;
        return entry;
    }

    pub fn isActiveGeneration(self: *const Registry, id: CapabilityId, generation: u32) bool {
        const entry = self.getActive(id) orelse return false;
        return entry.generation == generation;
    }

    pub fn revoke(self: *Registry, id: CapabilityId) RevokeError!void {
        const raw = @intFromEnum(id);
        if (raw == 0) return error.InvalidCapability;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return error.InvalidCapability;
        if (self.entries[index].revoked) return error.AlreadyRevoked;

        self.entries[index].revoked = true;
        self.entries[index].generation = self.next_generation;
        self.next_generation += 1;
    }

    pub fn delegate(
        self: *Registry,
        source: CapabilityId,
        rights: CapabilityRights,
    ) DelegateError!CapabilityId {
        const source_entry = self.getActive(source) orelse return error.InvalidCapability;
        if (!source_entry.rights.delegate) return error.DelegateRightRequired;
        if (!source_entry.rights.contains(rights)) return error.RightsEscalation;
        if (self.count >= self.entries.len) return error.RegistryFull;

        const id: CapabilityId = @enumFromInt(self.count + 1);
        self.entries[self.count] = .{
            .id = id,
            .target = source_entry.target,
            .rights = rights,
            .generation = self.next_generation,
            .revoked = false,
        };

        self.count += 1;
        self.next_generation += 1;
        return id;
    }

    pub fn at(self: *const Registry, index: usize) ?*const Capability {
        if (index >= self.count) return null;
        return &self.entries[index];
    }
};

test "capability registry grants rights to existing objects" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: Registry = .{};

    const target = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, target, .{ .read = true });

    try std.testing.expect(@intFromEnum(cap) == 1);

    const entry = capabilities.get(cap) orelse return error.TestExpectedEqual;
    try std.testing.expect(entry.target == target);
    try std.testing.expect(entry.rights.read);
    try std.testing.expect(!entry.rights.write);
    try std.testing.expect(!entry.revoked);
}

test "capability registry rejects invalid targets and exhaustion" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: Registry = .{};

    try std.testing.expectError(
        error.InvalidTarget,
        capabilities.grant(&objects, .invalid, .{ .read = true }),
    );

    const target = try objects.create(.framebuffer, "framebuffer");
    var index: usize = 0;
    while (index < max_capabilities) : (index += 1) {
        _ = try capabilities.grant(&objects, target, .{ .read = true });
    }

    try std.testing.expectError(
        error.RegistryFull,
        capabilities.grant(&objects, target, .{ .read = true }),
    );
}

test "capability rights reports containment" {
    const std = @import("std");

    const read_write: CapabilityRights = .{ .read = true, .write = true };

    try std.testing.expect(read_write.contains(.{ .read = true }));
    try std.testing.expect(read_write.contains(.{ .read = true, .write = true }));
    try std.testing.expect(!read_write.contains(.{ .execute = true }));
    try std.testing.expect(!read_write.contains(.{ .read = true, .delegate = true }));
}

test "capability registry revokes capabilities and rejects stale generations" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: Registry = .{};

    const target = try objects.create(.framebuffer, "framebuffer");
    const cap = try capabilities.grant(&objects, target, .{ .read = true });
    const entry = capabilities.getActive(cap) orelse return error.TestExpectedEqual;
    const generation = entry.generation;

    try std.testing.expect(capabilities.isActiveGeneration(cap, generation));
    try capabilities.revoke(cap);

    try std.testing.expect(capabilities.getActive(cap) == null);
    try std.testing.expect(!capabilities.isActiveGeneration(cap, generation));
    try std.testing.expectError(error.AlreadyRevoked, capabilities.revoke(cap));
}

test "capability registry delegates only within active source rights" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: Registry = .{};

    const target = try objects.create(.framebuffer, "framebuffer");
    const source = try capabilities.grant(
        &objects,
        target,
        .{ .read = true, .write = true, .delegate = true },
    );
    const child = try capabilities.delegate(source, .{ .read = true });

    const child_entry = capabilities.getActive(child) orelse return error.TestExpectedEqual;
    try std.testing.expect(child_entry.target == target);
    try std.testing.expect(child_entry.rights.read);
    try std.testing.expect(!child_entry.rights.write);
    try std.testing.expect(!child_entry.rights.delegate);

    try std.testing.expectError(
        error.RightsEscalation,
        capabilities.delegate(source, .{ .read = true, .execute = true }),
    );
}

test "capability registry rejects delegation without delegate right or active source" {
    const std = @import("std");

    var objects: object.Registry = .{};
    var capabilities: Registry = .{};

    const target = try objects.create(.framebuffer, "framebuffer");
    const read_only = try capabilities.grant(&objects, target, .{ .read = true });
    try std.testing.expectError(
        error.DelegateRightRequired,
        capabilities.delegate(read_only, .{ .read = true }),
    );

    const source = try capabilities.grant(&objects, target, .{ .read = true, .delegate = true });
    try capabilities.revoke(source);
    try std.testing.expectError(
        error.InvalidCapability,
        capabilities.delegate(source, .{ .read = true }),
    );
}
