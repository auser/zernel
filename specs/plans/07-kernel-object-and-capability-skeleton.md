# Plan 07: Kernel Object And Capability Skeleton

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

```text
kernel/src/object.zig
  ObjectId
  ObjectKind
  KernelObject
  Registry

kernel/src/capability.zig
  CapabilityId
  CapabilityRights
  Capability
  Registry
```

## API Sketch

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

## Checkpoints

- The kernel boots with the object registry initialized.
- Serial or framebuffer output can dump all registered objects.
- At least one capability points at a real object.
- Invalid object or capability ids fail cleanly.
- Host-side tests cover id allocation, registry exhaustion, and lookup.
