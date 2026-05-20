# Plan 13: Capability Hardening

## Status

In progress. Route creation checks source-cell ownership and route-kind rights.
Capability revocation, stale-generation rejection, and delegation rules are
implemented for the current fixed-size registries.

## Goal

Turn capabilities from registry metadata into the mandatory authority primitive
for every core operation.

## Why This Comes Next

Zernel's security model depends on explicit authority. Objects, cells, and
routes are only useful as security mechanisms if operations cannot bypass
capabilities through globals or ad hoc helper calls.

## Work Items

1. Add `CapabilityRights.contains(required)` and tests.
2. Define required rights for each route kind.
3. Reject route creation when the source cell does not own the capability.
4. Reject route creation when rights are insufficient.
5. Add capability generations to all authority checks so stale IDs can be
   detected after revocation.
6. Add revocation records and deny revoked capabilities.
7. Add delegation rules: delegation requires the source capability to carry
   `delegate`.
8. Move public mutation APIs behind capability-checked wrappers in
   `core/system.zig`.
9. Make future monitor mutation commands act through a monitor cell.

## Implementation Notes

Expected files:

```text
kernel/src/core/capability.zig
kernel/src/core/cell.zig
kernel/src/core/route.zig
kernel/src/core/system.zig
```

Rights shape:

```text
read       inspect or validate an object
write      mutate or transform an object
execute    start work, execute route handlers, or run a cell
delegate   derive another capability from this capability
```

## Validation

Required host tests:

```sh
zig test kernel/src/core/capability.zig
zig test kernel/src/core/cell.zig
zig test kernel/src/core/route.zig
```

Required boot checks:

```sh
make kernel-x86_64
make kernel-aarch64
```

## Done When

- All route creation paths enforce target, ownership, and rights.
- Revoked capabilities are rejected.
- Delegation cannot occur without `delegate`.
- Tests cover denial paths, not only success paths.

## Progress

- Done: rights containment helper.
- Done: route required-right checks.
- Done: source-cell ownership checks.
- Done: capability revocation flag.
- Done: cell capability slots store capability generation.
- Done: route creation rejects revoked/stale capabilities.
- Done: delegation requires an active source capability with `delegate`.
- Done: delegation cannot escalate beyond source rights.
- Done: delegated capabilities are attached to the target cell with generation.
- Done: core wrappers record provenance for revocation and delegation.
- Remaining: public mutation APIs behind capability-checked wrappers.
