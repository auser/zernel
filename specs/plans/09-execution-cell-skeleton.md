# Plan 09: Execution Cell Skeleton

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
- Link from a cell to an object id when the cell is represented as a kernel
  object.
- A small owned-capability list or owned-capability count.
- Debug dump of all known cells.
- A boot-time `kernel_boot` cell wired into the existing core state.
- A monitor command that dumps cells on demand.

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

Place the cell skeleton under `kernel/src/core/` next to objects and
capabilities. Cells are part of the same kernel model vocabulary: objects name
state, capabilities name authority, and cells name work. Keeping them together
also gives routes and provenance one obvious place to import these shared ids
and registries from later.

```text
kernel/src/core/cell.zig
  CellId
  CellKind
  CellState
  ExecutionCell
  Registry
```

Extend the integration module from Plan 08:

```text
kernel/src/core/system.zig
  initBoot
  createBootCell
  dumpCells
```

`cell.zig` defines the cell types and registry mechanics. `core/system.zig`
connects cells to the boot-created object and capability state.

## Implementation Details

File: `kernel/src/core/cell.zig`

```zig
const capability = @import("capability.zig");
const object = @import("object.zig");

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

pub const max_cells = 16;
pub const max_cell_capabilities = 4;
```

A cell connects to the existing object and capability model:

```zig
pub const ExecutionCell = struct {
    id: CellId,
    kind: CellKind,
    state: CellState,
    object_id: object.ObjectId,
    capabilities: [max_cell_capabilities]capability.CapabilityId,
    capability_count: usize = 0,
    budget_ticks: usize,
};
```

The first implementation is small but real:

```zig
pub const CreateError = error{
    RegistryFull,
    InvalidObject,
};

pub const TransitionError = error{
    InvalidCell,
    InvalidTransition,
};

pub const GrantError = error{
    InvalidCell,
    InvalidCapability,
    CapabilityListFull,
};

pub const Registry = struct {
    entries: [max_cells]ExecutionCell = undefined,
    count: usize = 0,

    pub fn reset(self: *Registry) void {
        self.count = 0;
    }

    pub fn create(
        self: *Registry,
        objects: *const object.Registry,
        kind: CellKind,
        object_id: object.ObjectId,
    ) CreateError!CellId {
        if (objects.get(object_id) == null) return error.InvalidObject;
        if (self.count >= self.entries.len) return error.RegistryFull;

        const id: CellId = @enumFromInt(self.count + 1);
        self.entries[self.count] = .{
            .id = id,
            .kind = kind,
            .state = .created,
            .object_id = object_id,
            .capabilities = [_]capability.CapabilityId{.invalid} ** max_cell_capabilities,
            .budget_ticks = 0,
        };

        self.count += 1;
        return id;
    }

    pub fn get(self: *const Registry, id: CellId) ?*const ExecutionCell {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn getMutable(self: *Registry, id: CellId) ?*ExecutionCell {
        const raw = @intFromEnum(id);
        if (raw == 0) return null;

        const index: usize = @intCast(raw - 1);
        if (index >= self.count) return null;
        return &self.entries[index];
    }

    pub fn transition(self: *Registry, id: CellId, next: CellState) TransitionError!void {
        const entry = self.getMutable(id) orelse return error.InvalidCell;
        if (!isValidTransition(entry.state, next)) return error.InvalidTransition;
        entry.state = next;
    }

    pub fn grantCapability(
        self: *Registry,
        caps: *const capability.Registry,
        id: CellId,
        cap: capability.CapabilityId,
    ) GrantError!void {
        const entry = self.getMutable(id) orelse return error.InvalidCell;
        if (caps.get(cap) == null) return error.InvalidCapability;
        if (entry.capability_count >= entry.capabilities.len) return error.CapabilityListFull;

        entry.capabilities[entry.capability_count] = cap;
        entry.capability_count += 1;
    }

    pub fn at(self: *const Registry, index: usize) ?*const ExecutionCell {
        if (index >= self.count) return null;
        return &self.entries[index];
    }
};

fn isValidTransition(from: CellState, to: CellState) bool {
    return switch (from) {
        .created => to == .ready,
        .ready => to == .running,
        .running => to == .blocked or to == .completed or to == .failed,
        .blocked => to == .ready,
        .completed, .failed => false,
    };
}
```

`transition` accepts only boring lifecycle movement:

```text
created -> ready
ready -> running
running -> blocked
blocked -> ready
running -> completed
running -> failed
```

Any other transition returns `error.InvalidTransition`.

Registry behavior:

```text
cell.Registry
  create validates the backing object id before allocating a cell id
  create initializes every cell in the created state
  get/getMutable reject CellId.invalid and out-of-range ids
  transition is the only way to change lifecycle state
  grantCapability validates the capability id and enforces max_cell_capabilities
  at returns entries by dense registry index for dumps
```

## Integration Contract

This plan must extend the state created by Plan 08. It should not create a
standalone cell registry that nothing else can see.

During boot, `core.initBoot` creates:

```text
object: execution_cell / "kernel_boot"
cell: kernel_boot -> object id for "kernel_boot"
capability: rights needed by the boot cell for the initial debug objects
```

Concrete `core/system.zig` additions:

File: `kernel/src/core/system.zig`

```zig
pub const cell = @import("cell.zig");

var cells: cell.Registry = .{};
var boot_cell: cell.CellId = .invalid;
var boot_cell_object: object.ObjectId = .invalid;

pub fn initBoot(info: *const BootInfo) void {
    // Existing Plan 08 object/cap setup first.
    cells.reset();

    boot_cell_object = createObject(.execution_cell, "kernel_boot");
    boot_cell = cells.create(&objects, .kernel_boot, boot_cell_object)
        catch panic("core cell registry init failed");
    cells.grantCapability(&capabilities, boot_cell, framebuffer_read_capability)
        catch panic("boot cell capability grant failed");
    cells.transition(boot_cell, .ready)
        catch panic("boot cell transition failed");
}

pub fn dumpCells() void {
    klog.info("cells");

    var index: usize = 0;
    while (index < cells.count) : (index += 1) {
        const entry = cells.at(index) orelse continue;
        klog.labelDec("  id", @intFromEnum(entry.id));
        klog.labelDec("  kind", @intFromEnum(entry.kind));
        klog.labelDec("  state", @intFromEnum(entry.state));
        klog.labelDec("  object", @intFromEnum(entry.object_id));
        klog.labelDec("  capabilities", entry.capability_count);
        klog.labelDec("  budget ticks", entry.budget_ticks);
    }
}

pub fn bootCell() cell.CellId {
    return boot_cell;
}
```

Add the serial monitor command:

```text
cells
```

The command calls:

```zig
core.dumpCells();
```

The route plan must use the `kernel_boot` cell id as the source for its first
debug route.

Monitor implementation:

File: `kernel/src/interaction/monitor.zig`

```zig
const core = @import("../core/system.zig");

// help string: commands: help boot mem fb objects caps cells clear halt
} else if (equals(line, "cells")) {
    core.dumpCells();
}
```

When Plan 10 is also implemented, the help string becomes:

```text
commands: help boot mem fb objects caps cells routes clear halt
```

Verification:

```text
make kernel-x86_64
zig test kernel/src/core/cell.zig
```

## Checkpoints

- The boot path registers a `kernel_boot` cell.
- The `kernel_boot` cell references a real `execution_cell` object.
- The boot cell has at least one associated capability or capability count.
- The cell registry can dump id, kind, state, and budget counters.
- The serial monitor supports `cells`.
- Invalid state transitions are rejected or logged.
- Host-side tests cover id allocation, lookup, and lifecycle transitions.
