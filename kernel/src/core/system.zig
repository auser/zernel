const boot_info = @import("../boot/info.zig");
const klog = @import("../utils/klog.zig");
const panic = @import("../utils/panic.zig").panic;

pub const object = @import("object.zig");
pub const capability = @import("capability.zig");
pub const cell = @import("cell.zig");
pub const route = @import("route.zig");

const BootInfo = boot_info.BootInfo;

var objects: object.Registry = .{};
var capabilities: capability.Registry = .{};
var cells: cell.Registry = .{};
var routes: route.Registry = .{};

var kernel_log_object: object.ObjectId = .invalid;
var framebuffer_object: object.ObjectId = .invalid;
var memory_map_object: object.ObjectId = .invalid;
var boot_cell_object: object.ObjectId = .invalid;

var framebuffer_read_capability: capability.CapabilityId = .invalid;
var memory_map_read_capability: capability.CapabilityId = .invalid;

var boot_cell: cell.CellId = .invalid;
var boot_inspect_route: route.RouteId = .invalid;

pub fn initBoot(info: *const BootInfo) void {
  _ = info;

  objects.reset();
  capabilities.reset();
  cells.reset();
  routes.reset();

  kernel_log_object = createObject(.kernel_log, "kernel_log");
  framebuffer_object = createObject(.framebuffer, "framebuffer");
  memory_map_object = createObject(.memory_region, "memory_map");
  boot_cell_object = createObject(.execution_cell, "kernel_boot");

  framebuffer_read_capability = grantCapability(framebuffer_object, .{ .read = true });
  memory_map_read_capability = grantCapability(memory_map_object, .{ .read = true });

  boot_cell = cells.create(&objects, .kernel_boot, boot_cell_object) catch
    panic("core cell registry init failed");
  cells.grantCapability(&capabilities, boot_cell, framebuffer_read_capability) catch
    panic("boot cell capability grant failed");
  cells.transition(boot_cell, .ready) catch panic("boot cell transition failed");

  boot_inspect_route = routes.create(
      &cells,
      &capabilities,
      &objects,
      .inspect_object,
      boot_cell,
      framebuffer_read_capability,
      framebuffer_object,
      .invalid,
  ) catch panic("boot route create failed");
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

pub fn dumpCells() void {
  klog.info("cells");

  var index: usize = 0;
  while (index < cells.count) : (index += 1) {
    const entry = cells.at(index) orelse continue;
    klog.labelDec("  id", @intFromEnum(entry.id));
    klog.labelDec("  kind", @intFromEnum(entry.kind));
    klog.labelDec("  state", @intFromEnum(entry.state));
    klog.labelDec("  object", @intFromEnum(entry.object_id));
    klog.labelDec("  capabilities", entry.capability_count);
    klog.labelDec("  budget ticks", entry.budget_ticks);
  }
}

pub fn dumpRoutes() void {
  klog.info("routes");

  var index: usize = 0;
  while (index < routes.count) : (index += 1) {
    const entry = routes.at(index) orelse continue;
    klog.labelDec("  id", @intFromEnum(entry.id));
    klog.labelDec("  kind", @intFromEnum(entry.kind));
    klog.labelDec("  status", @intFromEnum(entry.status));
    klog.labelDec("  source cell", @intFromEnum(entry.source_cell));
    klog.labelDec("  capability", @intFromEnum(entry.capability));
    klog.labelDec("  input object", @intFromEnum(entry.input_object));
    klog.labelDec("  output object", @intFromEnum(entry.output_object));
  }
}

pub fn objectRegistry() *const object.Registry {
  return &objects;
}

pub fn capabilityRegistry() *const capability.Registry {
  return &capabilities;
}

pub fn cellRegistry() *const cell.Registry {
  return &cells;
}

pub fn routeRegistry() *const route.Registry {
  return &routes;
}

pub fn framebufferObject() object.ObjectId {
  return framebuffer_object;
}

pub fn memoryMapObject() object.ObjectId {
  return memory_map_object;
}

pub fn bootCellObject() object.ObjectId {
  return boot_cell_object;
}

pub fn framebufferReadCapability() capability.CapabilityId {
  return framebuffer_read_capability;
}

pub fn memoryMapReadCapability() capability.CapabilityId {
  return memory_map_read_capability;
}

pub fn bootCell() cell.CellId {
  return boot_cell;
}

pub fn bootInspectRoute() route.RouteId {
  return boot_inspect_route;
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
