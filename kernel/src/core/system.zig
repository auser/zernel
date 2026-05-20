const boot_info = @import("../boot/info.zig");
const klog = @import("../utils/klog.zig");
const panic = @import("../utils/panic.zig").panic;

pub const object = @import("object.zig");
pub const capability = @import("capability.zig");

const BootInfo = boot_info.BootInfo;

var objects: object.Registry = .{};
var capabilities: capability.Registry = .{};

var kernel_log_object: object.ObjectId = .invalid;
var framebuffer_object: object.ObjectId = .invalid;
var memory_map_object: object.ObjectId = .invalid;

var framebuffer_read_capability: capability.CapabilityId = .invalid;
var memory_map_read_capability: capability.CapabilityId = .invalid;

pub fn initBoot(info: *const BootInfo) void {
  _ = info;

  objects.reset();
  capabilities.reset();

  kernel_log_object = createObject(.kernel_log, "kernel_log");
  framebuffer_object = createObject(.framebuffer, "framebuffer");
  memory_map_object = createObject(.memory_region, "memory_map");

  framebuffer_read_capability = grantCapability(framebuffer_object, .{ .read = true });
  memory_map_read_capability = grantCapability(memory_map_object, .{ .read = true });
}

pub fn dumpObjects() void {
  klog.info("objects");

  var index: usize = 0;
  while (index < objects.count) : (index += 1) {
    const entry = objects.at(index) orelse continue;
    klog.labelDec("  id", @intFromEnum(entry.id));
    klog.labelDec("  kind", @intFromEnum(entry.kind));
    klog.labelDec("  generation", entry.generation);
    klog.info(entry.name);
  }
}

pub fn dumpCapabilities() void {
  klog.info("capabilities");

  var index: usize = 0;
  while (index < capabilities.count) : (index += 1) {
    const entry = capabilities.at(index) orelse continue;
    klog.labelDec("  id", @intFromEnum(entry.id));
    klog.labelDec("  target", @intFromEnum(entry.target));
    klog.labelDec("  generation", entry.generation);
    dumpRights(entry.rights);
  }
}

pub fn objectRegistry() *const object.Registry {
  return &objects;
}

pub fn capabilityRegistry() *const capability.Registry {
  return &capabilities;
}

pub fn framebufferObject() object.ObjectId {
  return framebuffer_object;
}

pub fn memoryMapObject() object.ObjectId {
  return memory_map_object;
}

pub fn framebufferReadCapability() capability.CapabilityId {
  return framebuffer_read_capability;
}

pub fn memoryMapReadCapability() capability.CapabilityId {
  return memory_map_read_capability;
}

fn createObject(kind: object.ObjectKind, name: []const u8) object.ObjectId {
  return objects.create(kind, name) catch panic("core object registry full");
}

fn grantCapability(
  target: object.ObjectId,
  rights: capability.CapabilityRights,
) capability.CapabilityId {
  return capabilities.grant(&objects, target, rights) catch panic("core capability grant failed");
}

fn dumpRights(rights: capability.CapabilityRights) void {
  klog.labelDec("  read", boolToInt(rights.read));
  klog.labelDec("  write", boolToInt(rights.write));
  klog.labelDec("  execute", boolToInt(rights.execute));
  klog.labelDec("  delegate", boolToInt(rights.delegate));
}

fn boolToInt(value: bool) usize {
  return if (value) 1 else 0;
}
