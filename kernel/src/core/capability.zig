const object = @import("object.zig");

pub const CapabilityId = enum(u32) { invalid = 0, _ };

pub const CapabilityRights = packed struct(u32) {
  read: bool = false,
  write: bool = false,
  execute: bool = false,
  delegate: bool = false,
  reserved: u28 = 0,
};

pub const Capability = struct {
  id: CapabilityId,
  target: object.ObjectId,
  rights: CapabilityRights,
  generation: u32,
};

pub const max_capabilities = 32;

pub const GrantError = error{
  RegistryFull,
  InvalidTarget,
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
