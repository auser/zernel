# Plan 15: Memory Safety Foundation

## Status

In progress. PMM stats, range validation, overflow checks, and bootstrap heap
tests are implemented.

## Goal

Build the memory-management foundation needed for real isolation.

## Why This Comes Next

Capability checks are necessary but insufficient. A cell can only be contained
if the kernel owns physical pages correctly, maps virtual memory deliberately,
and catches memory faults with enough context to diagnose and kill the right
unit of work.

## Work Items

1. Audit PMM invariants and add host tests for bitmap accounting.
2. Add PMM stats accessors for total, free, used, reserved pages.
3. Add explicit reserve/free range APIs with alignment checks.
4. Add a fixed-size bootstrap heap or bump allocator for early kernel data.
5. Add a general kernel heap once VM ownership is clear.
6. Establish kernel page table ownership and mapping APIs.
7. Enforce W^X on kernel mappings.
8. Add guard pages for stacks and critical dynamic regions.
9. Track memory ownership by cell once scheduler state exists.
10. Extend page fault diagnostics with current-cell context.

## Expected Files

```text
kernel/src/mem/heap.zig
kernel/src/mem/pmm.zig
kernel/src/mem/page.zig
kernel/src/arch/x86_64/paging.zig
kernel/src/arch/aarch64/paging.zig
kernel/src/core/cell.zig
```

## Validation

```sh
cd kernel && zig test src/tests.zig
make kernel-x86_64
```

## Done When

- PMM accounting is test-covered.
- Kernel allocations have explicit failure behavior.
- Page mappings distinguish executable and writable memory.
- Fault logs can eventually identify the current cell.

## Progress

- Done: PMM stats accessor for total/free/used pages.
- Done: host tests for bitmap byte sizing.
- Done: host tests for mark/reserve accounting.
- Done: host tests for alloc/free accounting.
- Done: explicit public reserve/free range APIs with validation.
- Done: overflow-safe PMM range validation.
- Done: overflow-safe PMM initialization arithmetic for memory map bounds and bitmap placement.
- Done: fixed-size bootstrap heap with explicit allocation failures.
- Done: host tests for bootstrap heap alignment, page rollover, and failures.
- Done: early boot initializes PMM and the bootstrap heap.
- Done: PMM tracks page owner classes for reserved, kernel, heap, page-table,
  and cell pages.
- Done: heap and page-table allocations tag PMM ownership metadata.
- Done: owner-specific free rejects mismatched page owners.
- Done: cells have page counters for memory charged through core APIs.
- Done: typed mapping permissions reject writable executable kernel mappings.
- Remaining: VM-backed general kernel heap.
