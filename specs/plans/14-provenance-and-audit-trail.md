# Plan 14: Provenance And Audit Trail

## Status

In progress. Initial fixed-size provenance registry exists. Stable operation and
result names exist, and the monitor can emit machine-readable provenance lines.

## Goal

Make provenance a first-class append-only security mechanism for object,
capability, cell, and route state changes.

## Why This Comes Next

AI-native workloads require attribution. A kernel action should be answerable:
which cell requested it, which capability authorized it, which object changed,
which route carried it, and whether it succeeded or was denied.

## Work Items

1. Add stable operation and result name helpers.
2. Emit provenance for route status transitions.
3. Emit provenance for capability delegation and revocation.
4. Emit provenance for denied operations when attribution is possible.
5. Add a machine-readable provenance dump format.
6. Add monitor command `provenance-json`.
7. Add boot report fields for provenance capacity and dropped records.
8. Decide overflow behavior: panic in early boot, later preserve newest or fail
   closed depending on call site.
9. Add provenance sequence checks in host tests.

## Machine-Readable Shape

```text
__ZERNEL_PROVENANCE__ {"seq":1,"op":"object_created","result":"ok","object":1,"cell":0,"cap":0,"route":0}
```

Rules:

- ASCII only.
- Stable field names.
- No pointers or virtual addresses.
- One record per line.

## Validation

```sh
zig test kernel/src/core/provenance.zig
zig test kernel/src/core/route.zig
make kernel-x86_64
```

## Done When

- Every core state transition has a provenance event.
- Denials are recorded when they have valid identity.
- Host tooling can parse provenance without monitor interaction.

## Progress

- Done: fixed-size provenance registry.
- Done: boot-time object/capability/cell/route records.
- Done: stable operation/result names.
- Done: `provenance-json` monitor command.
- Done: core wrappers for capability revocation/delegation emit records.
- Done: core route transition wrapper emits records.
- Done: attributable route creation denials emit records.
- Remaining: overflow policy beyond early panic.
