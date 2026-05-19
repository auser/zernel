# Plan 09: Routing Plane Skeleton

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
- Route records that reference source cells and input/output objects.
- Basic validation that referenced ids exist.
- Debug dump of pending/completed routes.

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

```text
kernel/src/route.zig
  RouteId
  RouteKind
  RouteStatus
  RouteRequest
  Registry
```

## API Sketch

```zig
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

## Checkpoints

- The kernel can create a debug route from the boot cell.
- The route references existing object and capability ids.
- The route can transition from `pending` to `completed`.
- Registry dumps show source cell, route kind, status, and object ids.
- Host-side tests cover validation and lifecycle transitions.
