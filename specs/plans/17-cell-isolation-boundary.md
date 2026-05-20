# Plan 17: Cell Isolation Boundary

## Status

In progress. PMM page ownership metadata now has a cell owner class,
owner-specific free validation, per-cell page accounting, cell-aware mapping
validation, cell stack metadata with guard-page reservations, a tested virtual
stack layout, and per-cell address-space attachment state. This is still not
separate address-space enforcement.

## Goal

Make execution cells an isolation boundary rather than metadata.

## Why This Comes Next

AI-native workloads should be treated as untrusted work. A cell must not be able
to reach arbitrary kernel state, memory, devices, credentials, or routes just
because it is running.

## Work Items

1. Add per-cell capability table ownership as the only route authority source.
2. Add per-cell resource accounting fields.
3. Add kernel-service cell kind for trusted internal work.
4. Add lower-privilege execution plan: user mode on x86_64 first, or an
   equivalent staged boundary if user mode is deferred.
5. Add syscall or route-entry ABI sketch.
6. Add copy-in/copy-out validation rules.
7. Add fault containment: a fault in an untrusted cell should fail the cell, not
   silently corrupt kernel state.
8. Add tests for table exhaustion, denied capability lookup, and stale handles.
9. Add page ownership metadata for pages that will be assigned to cells.
10. Reject memory release when the releasing owner does not match the page owner.
11. Add stack allocation metadata that binds stack pages to a cell and reserves
    guard-page slots.
12. Add rollback rules for partially allocated cell stacks.
13. Add a virtual stack layout that can distinguish low guard, mapped stack
    pages, high guard, and out-of-layout addresses.
14. Add architecture mapper support that only maps stack data pages and verifies
    guard pages are unmapped.
15. Add per-cell address-space state for stack mappings.
16. Reject freeing mapped stacks until the unmap path exists.

## Expected Files

```text
kernel/src/core/cell.zig
kernel/src/core/capability.zig
kernel/src/core/address_space.zig
kernel/src/core/stack.zig
kernel/src/core/system.zig
kernel/src/mem/virtual.zig
kernel/src/mem/pmm.zig
kernel/src/arch/x86_64/paging.zig
kernel/src/arch/x86_64/descriptors.zig
kernel/src/arch/x86_64/interrupts.zig
```

## Validation

```sh
zig test kernel/src/core/cell.zig
zig test kernel/src/core/capability.zig
cd kernel && zig test src/tests.zig
make kernel-x86_64
```

## Done When

- Cell-owned capability tables are authoritative.
- There is a documented transition path toward lower-privilege execution.
- Faults can be attributed to cells.
- Denied access cannot bypass the route/capability layer.

## Progress

- Done: PMM owner tags include cell-owned pages.
- Done: PMM owner-specific free detects mismatched owners.
- Done: host tests cover owner classes and mismatched owner frees.
- Done: cell registry tracks per-cell memory page counts.
- Done: core APIs allocate/free pages on behalf of a concrete `CellId`.
- Done: cell memory allocation/free operations have provenance operation names.
- Done: mapping validation rejects pages not owned by the requesting cell.
- Done: stack registry binds stack metadata to a concrete cell.
- Done: stack metadata includes low/high guard-page reservations.
- Done: host tests cover virtual stack layout classification and guard-page
  mapping rejection.
- Done: x86_64 has a build-checked stack-page mapper primitive that validates
  cell page ownership, W^X permissions, and unmapped guard pages.
- Done: address-space registry tracks one address space per cell and attached
  stack mapping state.
- Done: core `mapCellStack` routes stack mapping through the architecture
  mapper.
- Done: mapped stacks cannot be freed until an unmap path exists.
- Done: core stack allocation uses cell-owned pages and rolls back partial
  allocation failures.
- Done: cell stack allocation/free operations have provenance operation names.
- Remaining: add unmap support for mapped stacks.
- Remaining: add a cell launch path that exercises `mapCellStack` at runtime.
- Remaining: separate root page tables per address space.
