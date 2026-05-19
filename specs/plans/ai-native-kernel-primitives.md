# AI-Native Kernel Primitives

## Purpose

This note defines the vocabulary that should guide Zernel as it grows beyond
bootstrapping. It is not an implementation plan by itself. The step-by-step
plans should introduce these ideas only when the kernel has enough foundation to
make them observable and testable.

The guiding idea is simple: Zernel should expose AI-native primitives directly
instead of treating model and agent workloads as ordinary Unix processes glued
together with files, sockets, and environment variables.

## Why This Exists

The next code plans need shared language before they introduce objects,
capabilities, cells, routes, and memory planes. Without this note, each plan
would have to redefine the same concepts, and the implementation could drift
toward disconnected subsystems instead of one coherent kernel model.

This document is needed for:

- explaining why the post-console plans introduce AI-native primitives before
  storage, networking, or model execution;
- keeping mechanism and policy separate while PMM and VM are still being built;
- giving later implementation plans consistent names for authority, work, state,
  memory policy, routing, and provenance;
- making it clear that the first AI-native step is a small inspectable skeleton,
  not an immediate in-kernel model runtime.

## Design Rules

- Build boring kernel foundations first: memory, interrupts, timers, console,
  allocator, and diagnostics.
- Introduce AI-native concepts as small kernel mechanisms before adding model
  execution, networking, persistence, or graphical workflows.
- Prefer explicit authority over ambient authority. An agent or cell should act
  through capabilities, not global privilege.
- Record provenance for state changes early, even if the first record format is
  only an in-memory debug structure.
- Keep policy separable from mechanisms. The PMM and page tables should stay
  correct and understandable; memory policy can sit above them.

## Core Vocabulary

### Kernel Object

A typed piece of kernel-managed state.

Examples:

- framebuffer surface
- log buffer
- memory region descriptor
- credential placeholder
- tensor metadata
- agent memory item
- route request

Early form:

- `ObjectId`
- `ObjectKind`
- metadata only
- fixed-size registry
- serial/framebuffer debug dump

Later form:

- versioned content
- provenance records
- persistent storage
- references between objects
- capability-gated mutation

### Capability

An explicit token of authority.

Examples:

- read object metadata
- mutate an object
- allocate memory from a plane
- use a credential
- send a route request
- start or stop a cell

Early form:

- `CapabilityId`
- target object or subsystem
- rights bitset
- fixed-size registry
- no security claims beyond API discipline

Later form:

- delegation
- revocation
- expiration
- audit/provenance linkage
- per-cell capability tables

### Execution Cell

A schedulable unit of work broader than a Unix process.

Examples:

- kernel shell command
- device service
- future user task
- model call
- agent loop
- validation pass
- render task

Early form:

- `CellId`
- `CellKind`
- lifecycle state
- budget counters
- owned capabilities
- debug registry

Later form:

- scheduling integration
- isolation
- syscall or route entry
- failure accounting
- resource leases

### Memory Plane

A policy layer over physical and virtual memory.

Examples:

- boot memory
- kernel memory
- device memory
- shared memory
- ephemeral agent memory
- persistent object memory
- model/tensor memory

Early form:

- names and metadata only
- counters backed by the PMM/VM
- no change to the low-level allocator contract

Later form:

- budgets
- reclamation policy
- promotion/demotion
- shared mappings
- device constraints

### Route

A typed request for work.

Examples:

- transform object A into object B
- validate a state transition
- ask a model
- run a tensor operation
- send a packet
- schedule a cell

Early form:

- `RouteId`
- source cell
- target kind
- input object ids
- requested operation enum
- status and error code

Later form:

- engine registry
- budget enforcement
- fallback paths
- remote execution
- model/tool selection

### Provenance

A record of why and how state changed.

Early form:

- object id
- cell id
- capability id
- operation kind
- monotonic sequence number

Later form:

- timestamps
- parent object versions
- validation result
- signatures or integrity metadata
- queryable audit log

## Near-Term Milestone Boundary

The first AI-native milestone should be the smallest useful skeleton:

```text
Object registry + capability registry + debug dump
```

It should not include:

- filesystem semantics
- networking
- model calls
- persistence
- user mode
- dynamic allocation unless a heap already exists
- claims of complete security isolation

This gives the kernel its intended shape early while keeping the boot path
small enough to debug.
