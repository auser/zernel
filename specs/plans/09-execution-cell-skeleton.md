# Plan 08: Execution Cell Skeleton

## Goal

Introduce execution cells as Zernel's general unit of work.

A cell is broader than a Unix process. It can eventually represent a shell
command, driver service, future user task, model call, agent loop, validation
pass, or render task. This plan only creates metadata and lifecycle tracking.

## Why This Comes Next

The next code needs a general way to name work before we build scheduling,
shell commands, drivers, or agent loops. If the kernel starts with only
processes, every later AI-native activity has to pretend to be a Unix process or
become a special case. Cells let us model work uniformly while deferring real
context switching and isolation.

Execution cells are needed for:

- attaching capabilities to the work that is allowed to use them;
- tracking lifecycle state and failure for kernel tasks;
- giving routes a source identity for provenance;
- preparing for timers, scheduling, and budgets later;
- representing future model calls, validation passes, and agent loops without
  forcing them into a process-only design.

## What We Will Build

- `CellId` value type.
- `CellKind` enum.
- `CellState` enum.
- Fixed-size cell registry.
- Optional link from a cell to an object id.
- Optional list or count of capabilities owned by a cell.
- Debug dump of all known cells.

## Non-Goals

- No scheduler integration.
- No context switching.
- No user mode.
- No model execution.
- No preemption.
- No isolation claims.

## Concepts To Understand First

### Process Is One Possible Cell

Traditional processes can be modeled as one cell kind later. Starting with cells
lets the kernel represent other work types without forcing everything through a
process abstraction.

### Lifecycle Before Scheduling

Track lifecycle state before adding scheduling:

```text
created -> ready -> running -> blocked -> completed
                       |
                       v
                    failed
```

The first implementation can move states manually during boot smoke tests.

### Budget Hooks

Cells should eventually carry resource budgets. The skeleton can reserve fields
for counters without enforcing policy yet.

## Proposed Layout

```text
kernel/src/cell.zig
  CellId
  CellKind
  CellState
  ExecutionCell
  Registry
```

## API Sketch

```zig
pub const CellId = enum(u32) { invalid = 0, _ };

pub const CellKind = enum(u16) {
    kernel_boot,
    shell_command,
    driver_service,
    route_worker,
    agent_loop,
};

pub const CellState = enum(u8) {
    created,
    ready,
    running,
    blocked,
    completed,
    failed,
};
```

## Checkpoints

- The boot path registers a `kernel_boot` cell.
- The cell registry can dump id, kind, state, and budget counters.
- Invalid state transitions are rejected or logged.
- Host-side tests cover id allocation, lookup, and lifecycle transitions.
