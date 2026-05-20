# Plan 12: AI-Native Security Roadmap

## Goal

Grow Zernel into a proper AI-native kernel with security as the central design
constraint.

This plan replaces external integration work as the immediate focus. MVM and
other runtimes can be useful long-term consumers, but the kernel should first
stand on its own: correct low-level isolation, explicit authority, provenance,
resource budgets, and typed work routing.

## Why This Comes Next

The current kernel has the first inspectable AI-native skeleton:

- objects name kernel-managed state;
- capabilities name explicit authority;
- cells name work;
- routes name typed work requests;
- provenance records explain state changes;
- the monitor can inspect the registries.

That is the right shape, but it is not yet a security boundary. The next work
must turn the skeleton into enforced kernel mechanisms before adding model
runtime complexity, networking, storage, or external orchestration.

## Design Rules

- Keep model runtimes out of ring 0.
- Prefer capability-gated APIs over ambient globals.
- Make every state transition attributable to a cell, capability, and route.
- Build isolation before convenience.
- Make denial paths as testable as success paths.
- Keep mechanisms separate from policy.
- Treat AI workloads as untrusted work, not privileged kernel extensions.

## Milestone 1: Capability Enforcement

Capabilities must become mandatory on every core operation.

Already started:

- route creation verifies referenced ids exist;
- route creation verifies the source cell owns the capability;
- route creation verifies the capability targets the input object.

Next checks:

- each route kind must declare required rights;
- route creation must reject insufficient rights;
- object mutation must require a write capability;
- cell start/stop must require an execute or control capability;
- delegation must require the delegate right;
- monitor commands that mutate state must act through a monitor cell and
  explicit capabilities.

Expected files:

```text
kernel/src/core/capability.zig
  CapabilityRights.contains

kernel/src/core/route.zig
  requiredRights
  CreateError.CapabilityRightsInsufficient
```

Checkpoint:

```sh
zig test kernel/src/core/capability.zig
zig test kernel/src/core/route.zig
```

## Milestone 2: Provenance As A First-Class Subsystem

Provenance should cover every meaningful state transition.

Required events:

- object created;
- capability granted;
- capability delegated;
- capability revoked;
- cell created;
- cell transitioned;
- route created;
- route accepted;
- route completed;
- route failed;
- denial recorded.

Security rule:

Denied operations should produce provenance records when there is enough valid
identity to attribute the denial.

Expected files:

```text
kernel/src/core/provenance.zig
  operation names
  result names
  append-only record API

kernel/src/core/system.zig
  record wrappers for core operations
```

Checkpoint:

The monitor can dump both human-readable and machine-readable provenance.

## Milestone 3: Memory Safety Foundation

The AI-native layer is only meaningful if memory isolation is real.

Required work:

- finish PMM invariants and tests;
- build a kernel heap with explicit allocation failure behavior;
- establish kernel page table ownership;
- enforce W^X mappings;
- add guard pages for stacks and critical regions;
- reserve device memory explicitly;
- add page fault diagnostics that identify the current cell once cells are
  schedulable.

Non-goal:

Do not add memory-plane policy before the low-level allocator and mappings are
boring and correct.

## Milestone 4: Cell Isolation And Scheduling

Cells must become the unit of isolation, not only metadata.

Required work:

- current cell identity;
- timer tick;
- budget counters;
- run queue;
- failure accounting;
- kernel service cells;
- user-mode or lower-privilege execution path;
- per-cell capability tables;
- per-cell memory/accounting hooks.

Security rule:

A cell should not be able to access an object, route, device, credential, or
memory plane unless its capability table grants that authority.

## Milestone 5: Route Dispatch Boundary

Routes should become the only general path for requesting cross-subsystem work.

Required work:

- route queue;
- route executor registry;
- route status transitions with provenance;
- budget checks before accept;
- capability checks before accept;
- denial results that are observable;
- no direct model/tool/device invocation bypassing routes.

First route families:

```text
inspect_object
validate_object
transform_object
render_surface
schedule_cell
allocate_memory
request_tool
```

## Milestone 6: AI-Native Object Model

Add object kinds that are useful for AI workloads without adding model runtime
complexity.

Candidate object kinds:

- prompt descriptor;
- model request descriptor;
- tool request descriptor;
- credential placeholder;
- memory item;
- tensor metadata;
- validation result;
- audit bundle.

Security rule:

Credentials are never ambient. A credential object can only be used through a
capability and a route that records provenance.

## Milestone 7: Policy Layer

Policy should sit above mechanisms.

Policy inputs:

- cell kind;
- capability rights;
- route kind;
- object kind;
- memory plane;
- budget;
- provenance history.

Policy outputs:

- accept;
- deny;
- require validation route;
- require human or host approval later;
- restrict budget;
- revoke capability.

Do not bake one AI product's policy into low-level memory, object, or route
code.

## Milestone 8: External Integration Boundary

Only after the kernel has real enforcement should external systems consume it.

Examples:

- MVM diagnostic guest;
- host-side audit collector;
- model engine service;
- remote route executor;
- developer monitor tooling.

These integrations should depend on stable kernel facts:

- boot report;
- provenance stream;
- route protocol;
- explicit capabilities;
- documented denial behavior.

## Immediate Next Work

Finish Milestone 1:

```text
route kind -> required rights -> enforced at route creation
```

Then move to Milestone 2:

```text
machine-readable provenance records and denial events
```
