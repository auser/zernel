pub const ObjectId = enum(u32) { invalid = 0, _ };

pub const ObjectKind = enum(u16) {
  kernel_log,
  framebuffer,
  memory_region,
  route_request,
  execution_cell,
};

pub const KernelObject = struct {
  id: ObjectId,
  kind: ObjectKind,
  generation: u32,
  name: []const u8,
};

pub const max_objects = 32;

pub const CreateError = error{
  RegistryFull,
};

pub const Registry = struct {
  entries: [max_objects]KernelObject = undefined,
  count: usize = 0,
  next_generation: u32 = 1,

  pub fn reset(self: *Registry) void {
    self.count = 0;
    self.next_generation = 1;
  }

  pub fn create(self: *Registry, kind: ObjectKind, name: []const u8) CreateError!ObjectId {
    if (self.count >= self.entries.len) return error.RegistryFull;

    const id: ObjectId = @enumFromInt(self.count + 1);
    self.entries[self.count] = .{
      .id = id,
      .kind = kind,
      .generation = self.next_generation,
      .name = name,
    };

    self.count += 1;
    self.next_generation += 1;
    return id;
  }

  pub fn get(self: *const Registry, id: ObjectId) ?*const KernelObject {
    const raw = @intFromEnum(id);
    if (raw == 0) return null;

    const index: usize = @intCast(raw - 1);
    if (index >= self.count) return null;
    return &self.entries[index];
  }

  pub fn at(self: *const Registry, index: usize) ?*const KernelObject {
    if (index >= self.count) return null;
    return &self.entries[index];
  }
};

test "object registry allocates ids and looks up entries" {
  const std = @import("std");

  var registry: Registry = .{};
  const first = try registry.create(.kernel_log, "kernel_log");
  const second = try registry.create(.framebuffer, "framebuffer");

  try std.testing.expect(@intFromEnum(first) == 1);
  try std.testing.expect(@intFromEnum(second) == 2);

  const first_object = registry.get(first) orelse return error.TestExpectedEqual;
  try std.testing.expect(first_object.kind == .kernel_log);
  try std.testing.expectEqualStrings("kernel_log", first_object.name);

  try std.testing.expect(registry.get(.invalid) == null);
}

test "object registry reports exhaustion" {
  const std = @import("std");

  var registry: Registry = .{};
  var index: usize = 0;
  while (index < max_objects) : (index += 1) {
    _ = try registry.create(.memory_region, "memory_region");
  }

  try std.testing.expectError(error.RegistryFull, registry.create(.memory_region, "overflow"));
}
