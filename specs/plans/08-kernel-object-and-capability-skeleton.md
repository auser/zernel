# Plan 08: Kernel Object And Capability Skeleton

## Goal

Introduce the first AI-native kernel primitive: typed kernel objects protected by
explicit capabilities.

This is a skeleton, not a security boundary yet. The point is to establish the
shape of the APIs and make the state visible through debug output before storage,
networking, user mode, or model execution exist.

## Why This Comes Next

The next code needs the first AI-native vocabulary in the kernel while the
system is still small enough to inspect. If storage, networking, shell commands,
and agent features are added first, they will likely grow around ad hoc globals
and Unix-like assumptions. A tiny object and capability skeleton gives later
subsystems a common way to name state and authority.

Objects and capabilities are needed for:

- representing kernel-managed state without treating everything as a file;
- requiring explicit authority for future operations;
- linking future cells and routes to the state they affect;
- recording provenance for object changes later;
- giving credentials, memory regions, framebuffers, tensors, and agent memory a
  shared metadata shape.

## What We Will Build

- `ObjectId` and `CapabilityId` value types.
- `ObjectKind` enum.
- `CapabilityRights` bitset.
- Fixed-size object and capability registries.
- Functions to create objects, grant capabilities, and dump registry state.
- A boot-time smoke test that creates a few objects and capabilities.
- Monitor commands that dump objects and capabilities on demand.
- Host-side tests for pure registry behavior where possible.

## Non-Goals

- No filesystem.
- No persistence.
- No networking.
- No model calls.
- No dynamic allocation unless a heap exists.
- No claim that capabilities are an enforced security boundary yet.

## Concepts To Understand First

### Objects Before Files

Unix starts with files as a dominant abstraction. Zernel should start with typed
kernel objects. A file may become one object kind later, but it should not be the
root concept.

### Capabilities Before Ambient Authority

An execution context should not be able to operate on any object just because it
runs in the kernel. Early code will still be trusted, but the API should require
a capability argument for operations that represent authority.

### Fixed-Size First

A fixed-size registry is easier to boot, inspect, and test than a heap-backed
registry. Replace it later when the allocator is ready.

## Proposed Layout

Place these modules under `kernel/src/core/`. Objects and capabilities are
cross-cutting kernel model primitives, not architecture support, boot parsing,
memory management, framebuffer code, or generic utilities. Keeping them in a
dedicated `core` directory gives later cells, routes, memory planes, and
provenance code one obvious namespace to depend on.

```text
kernel/src/core/object.zig
  ObjectId
  ObjectKind
  KernelObject
  Registry

kernel/src/core/capability.zig
  CapabilityId
  CapabilityRights
  Capability
  Registry

kernel/src/core/system.zig
  boot-time core state
  initBoot
  dumpObjects
  dumpCapabilities
```

`object.zig` and `capability.zig` should stay mostly pure: value types,
registry storage, and registry operations. `system.zig` is the integration
module that owns the initial global registries while the kernel has no allocator
or dependency injection story.

## Implemented API Shape

```zig
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
```

Capabilities can start as rights over a single object:

```zig
pub const CapabilityRights = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    delegate: bool = false,
    reserved: u28 = 0,
};
```

The implementation includes fixed-size registries. Keep the local type name
`Registry` in each module and rely on module qualification at use sites:

```zig
var objects: object.Registry = .{};
var capabilities: capability.Registry = .{};
```

File: `kernel/src/core/object.zig`

Object registry implementation:

```zig
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
```

File: `kernel/src/core/capability.zig`

Capability registry implementation:

```zig
pub const CapabilityId = enum(u32) { invalid = 0, _ };

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
```

File behavior:

```text
object.Registry
  reset clears count and generation state
  create allocates ids from count + 1 and returns RegistryFull when full
  get rejects ObjectId.invalid and out-of-range ids
  at returns entries by dense registry index for dumps

capability.Registry
  reset clears count and generation state
  grant validates the target object before allocating a capability id
  grant returns InvalidTarget before RegistryFull for bad object ids
  get rejects CapabilityId.invalid and out-of-range ids
  at returns entries by dense registry index for dumps
```

## Integration Contract

This plan is not done when the types compile. The object and capability
registries are connected to boot and interaction so they are observable.

`main.zig` initializes the core state after boot info is loaded and before
entering the monitor:

File: `kernel/src/main.zig`

```zig
const core = @import("core/system.zig");

const info = boot_info.load();
boot_info.validate(&info);
core.initBoot(&info);
```

`core.initBoot` creates real objects for current kernel state:

File: `kernel/src/core/system.zig`

```text
kernel_log
framebuffer
memory_region
```

It also grants read capabilities over real objects:

```text
framebuffer read capability -> framebuffer object
memory map read capability -> memory map object
```

The monitor has commands that make the new state visible:

File: `kernel/src/interaction/monitor.zig`

```text
objects
caps
```

Those commands call:

```zig
core.dumpObjects();
core.dumpCapabilities();
```

The dumps should use `klog`, so they appear on serial and framebuffer output.
Later plans must build on these ids instead of creating disconnected registries.

## Implemented Files

```text
kernel/src/core/object.zig
kernel/src/core/capability.zig
kernel/src/core/system.zig
kernel/src/main.zig
kernel/src/interaction/monitor.zig
```

Verification:

```text
make kernel-x86_64
zig test kernel/src/core/object.zig
zig test kernel/src/core/capability.zig
```

## Checkpoints

- The kernel boots with the object registry initialized.
- Serial or framebuffer output can dump all registered objects.
- At least one capability points at a real object.
- The serial monitor supports `objects` and `caps`.
- Invalid object or capability ids fail cleanly.
- Host-side tests cover id allocation, registry exhaustion, and lookup.
