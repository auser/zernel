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

pub const CapabilityRights = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    delegate: bool = false,
    reserved: u28 = 0,
};
