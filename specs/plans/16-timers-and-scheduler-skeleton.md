# Plan 16: Timers And Scheduler Skeleton

## Status

In progress. Core scheduler state, current-cell identity, and budget tick
accounting are implemented in host-tested code. Hardware timer integration is
still remaining.

## Goal

Introduce time, ticks, budgets, and the first scheduler structure for execution
cells.

## Why This Comes Next

Cells currently describe work but do not run under kernel control. Production
security needs budgets, timeouts, fault handling, and a clear current-cell
identity before cells can represent agent loops, drivers, or user tasks.

## Work Items

1. Add architecture facade for timer initialization.
2. Add x86_64 timer interrupt path.
3. Add monotonic tick counter.
4. Add current-cell pointer or ID in core state.
5. Add per-cell budget counters.
6. Add run queue metadata.
7. Add lifecycle transitions through scheduler-owned APIs.
8. Record provenance on scheduler transitions.
9. Add monitor command for scheduler state.

## Expected Files

```text
kernel/src/arch.zig
kernel/src/arch/x86_64/interrupts.zig
kernel/src/core/cell.zig
kernel/src/core/scheduler.zig
kernel/src/core/system.zig
kernel/src/interaction/monitor.zig
```

## Validation

```sh
zig test kernel/src/core/cell.zig
make kernel-x86_64
```

Boot checkpoint:

```text
monitor command: cells
monitor command: scheduler
```

## Done When

- Kernel has a monotonic tick source.
- A current cell can be named.
- Cell budget fields are updated through scheduler APIs.
- Scheduler transitions are provenance-recorded.

## Progress

- Done: core scheduler state with monotonic tick counter.
- Done: scheduler-owned current-cell selection.
- Done: budget tick accounting for the running current cell.
- Done: boot marks the boot cell as the current running cell.
- Done: monitor command for scheduler state.
- Done: architecture timer initialization facade.
- Done: monitor-driven scheduler tick command for exercising tick accounting.
- Remaining: hardware timer programming behind the architecture facade.
- Remaining: x86_64 timer interrupt path calls scheduler tick.
- Remaining: provenance on runtime scheduler transitions beyond boot current-cell selection.
