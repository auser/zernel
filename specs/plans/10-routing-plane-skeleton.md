# Plan 10: Routing Plane Skeleton

## Goal

Introduce routes as typed requests for work.

The routing plane is where Zernel can eventually decide whether work should be
handled by kernel code, a driver, a user task, a model, an agent, or a remote
peer. This plan only creates the data model and debug flow.

## Why This Comes Next

The next code needs a typed path for requesting work once objects, capabilities,
and cells exist. Direct function calls are fine inside one subsystem, but they do
not leave a durable record of who requested work, what authority they used, what
objects were involved, or what policy should decide the executor. A route record
creates that future control point without adding model or network complexity.

The routing skeleton is needed for:

- connecting source cells to object operations through capabilities;
- recording provenance for requested work;
- separating "what work is requested" from "which engine performs it";
- preparing for validation, transformation, rendering, model, and device
  requests;
- giving future budget and policy code one place to intercept work.

## What We Will Build

- `RouteId` value type.
- `RouteKind` enum.
- `RouteStatus` enum.
- Fixed-size route registry.
- Route records that reference source cells, capabilities, and input/output
  objects.
- Basic validation that referenced ids exist.
- Debug dump of pending/completed routes.
- A boot-time debug route that uses the `kernel_boot` cell from Plan 09.
- A monitor command that dumps routes on demand.

## Non-Goals

- No engine registry.
- No model calls.
- No network forwarding.
- No async scheduler.
- No queueing beyond a fixed-size registry.
- No policy optimization.

## Concepts To Understand First

### Routes Are Typed Work Requests

A route should describe intended work without binding immediately to an
implementation.

Examples:

```text
transform object
validate object
inspect memory region
render surface
send packet
run model
```

The early kernel should only support harmless debug route kinds.

### Policy Comes Later

The skeleton should not try to choose the best model, accelerator, or remote
node. It only creates a place where those choices can later live.

### Provenance Starts Here

Each route should record the source cell and capability used to request it. That
is the first step toward traceable state changes.

## Proposed Layout

Place routes under `kernel/src/core/` with objects, capabilities, and cells.
Routes are the first structure that ties those primitives together: source work
requests an operation through a capability over one or more objects.

```text
kernel/src/core/route.zig
  RouteId
  RouteKind
  RouteStatus
  RouteRequest
  Registry
```

Extend the integration module from the previous plans:

```text
kernel/src/core/system.zig
  createDebugRoute
  dumpRoutes
```

## Implementation Details

File: `kernel/src/core/route.zig`

```zig
const capability = @import("capability.zig");
const cell = @import("cell.zig");
const object = @import("object.zig");

pub const RouteId = enum(u32) { invalid = 0, _ };

pub const RouteKind = enum(u16) {
    inspect_object,
    validate_object,
    transform_object,
    render_surface,
};

pub const RouteStatus = enum(u8) {
    pending,
    accepted,
    completed,
    failed,
};
```

Routes must depend on earlier core ids:

```zig
pub const RouteRequest = struct {
    id: RouteId,
    kind: RouteKind,
    status: RouteStatus,
    source_cell: cell.CellId,
    capability: capability.CapabilityId,
    input_object: object.ObjectId,
    output_object: object.ObjectId,
};
```

The first implementation can use `ObjectId.invalid` for `output_object` if a
debug route only inspects state.

The first route registry is fixed-size and validates every referenced id:

```zig
pub const max_routes = 16;

pub const CreateError = error{
    RegistryFull,
    InvalidSourceCell,
    InvalidCapability,
    InvalidInputObject,
    CapabilityTargetMismatch,
};

pub const TransitionError = error{
    InvalidRoute,
    InvalidTransition,
};

pub const Registry = struct {
    entries: [max_routes]RouteRequest = undefined,
    count: usize = 0,

    pub fn reset(self: *Registry) void {
        self.count = 0;
    }

    pub fn create(
        self: *Registry,
        cells: *const cell.Registry,
        caps: *const capability.Registry,
        objects: *const object.Registry,
        kind: RouteKind,
        source_cell: cell.CellId,
        cap: capability.CapabilityId,
        input_object: object.ObjectId,
        output_object: object.ObjectId,
    ) CreateError!RouteId {
        if (cells.get(source_cell) == null) return error.InvalidSourceCell;
        const cap_entry = caps.get(cap) orelse return error.InvalidCapability;
        if (objects.get(input_object) == null) return error.InvalidInputObject;
        if (cap_entry.target != input_object) return error.CapabilityTargetMismatch;
        if (self.count >= self.entries.len) return error.RegistryFull;

        const id: RouteId = @enumFromInt(self.count + 1);
        self.entries[self.count] = .{
            .id = id,
            .kind = kind,
            .status = .pending,
            .source_cell = source_cell,
            .capability = cap,
            .input_object = input_object,
            .output_object = output_object,
        };

        self.count += 1;
        return id;
    }

    pub fn get(self: *const Registry, id: RouteId) ?*const RouteRequest {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn transition(self: *Registry, id: RouteId, next: RouteStatus) TransitionError!void {
        const raw = @intFromEnum(id);
        if (raw == 0) return error.InvalidRoute;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return error.InvalidRoute;
        if (!isValidTransition(self.entries[index].status, next)) {
            return error.InvalidTransition;
        }

        self.entries[index].status = next;
    }

    pub fn at(self: *const Registry, index: usize) ?*const RouteRequest {
        if (index >= self.count) return null;
        return &self.entries[index];
    }
};

fn isValidTransition(from: RouteStatus, to: RouteStatus) bool {
    return switch (from) {
        .pending => to == .accepted or to == .failed,
        .accepted => to == .completed or to == .failed,
        .completed, .failed => false,
    };
}
```

`create` must check:

```zig
if (cells.get(source_cell) == null) return error.InvalidSourceCell;
const cap_entry = caps.get(cap) orelse return error.InvalidCapability;
if (objects.get(input_object) == null) return error.InvalidInputObject;
if (cap_entry.target != input_object) return error.CapabilityTargetMismatch;
```

The first valid status movement can be:

```text
pending -> accepted
accepted -> completed
pending -> failed
accepted -> failed
```

Registry behavior:

```text
route.Registry
  create validates source cell, capability, and input object before allocation
  create verifies the capability targets the requested input object
  create initializes every route in the pending state
  get rejects RouteId.invalid and out-of-range ids
  transition is the only way to change route status
  at returns entries by dense registry index for dumps
```

## Integration Contract

This plan is specifically about connecting the earlier primitives. It is not
complete if routes can be created without validating their references.

Route creation rejects:

```text
missing source cell
missing capability
missing input object
capability that does not target the input object
```

During boot, `core.initBoot` or a follow-up `core.createDebugRoute` creates one
harmless route:

```text
source_cell: kernel_boot
capability: read capability for framebuffer or memory map object
input_object: framebuffer or memory map object
kind: inspect_object
status: completed or pending
```

Concrete `core/system.zig` additions:

File: `kernel/src/core/system.zig`

```zig
pub const route = @import("route.zig");

var routes: route.Registry = .{};
var boot_inspect_route: route.RouteId = .invalid;

pub fn initBoot(info: *const BootInfo) void {
    // Existing Plan 08 and Plan 09 setup first.
    routes.reset();

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
```

Add the serial monitor command:

```text
routes
```

The command calls:

```zig
core.dumpRoutes();
```

At this point the monitor can show the whole chain:

```text
objects -> caps -> cells -> routes
```

That chain is the minimum proof that the skeletons are connected.

Monitor implementation:

File: `kernel/src/interaction/monitor.zig`

```zig
const core = @import("../core/system.zig");

// help string: commands: help boot mem fb objects caps cells routes clear halt
} else if (equals(line, "routes")) {
    core.dumpRoutes();
}
```

Verification:

```text
make kernel-x86_64
zig test kernel/src/core/route.zig
```

## Checkpoints

- The kernel can create a debug route from the boot cell.
- The route references existing object and capability ids.
- Route creation validates those references.
- At least one route uses a capability that targets its input object.
- The route can transition from `pending` to `completed`.
- Registry dumps show source cell, route kind, status, and object ids.
- The serial monitor supports `routes`.
- Host-side tests cover validation and lifecycle transitions.
