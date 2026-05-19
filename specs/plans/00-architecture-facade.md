# Plan 00: Architecture Facade

## Goal

Keep shared kernel code independent from the CPU architecture it is compiled
for.

The kernel currently builds for both x86_64 and aarch64. Some operations are
architecture-specific, such as serial output, halt instructions, port I/O, page
tables, and interrupt setup. Shared code like `_start`, `klog`, panic handling,
and memory management should not import `arch/x86_64/...` directly.

Instead, shared code imports one facade:

```zig
const arch = @import("arch.zig");
```

The facade selects the current architecture module at compile time.

## What We Will Build

- A top-level `kernel/src/arch.zig` facade.
- One module per architecture, such as:
  - `kernel/src/arch/x86_64.zig`
  - `kernel/src/arch/aarch64.zig`
- A small common architecture API:
  - `initEarlyDebug()`
  - `writeEarlyDebug(message)`
  - `halt()`
- Shared kernel code that calls the facade instead of architecture-specific
  files.

## Concepts To Understand First

- `builtin.cpu.arch` tells Zig which architecture is being compiled.
- `switch (builtin.cpu.arch)` is resolved at compile time for a freestanding
  target.
- Architecture-specific code can stay isolated in architecture modules.
- Shared code should depend on behavior, not on x86_64 or aarch64 file paths.

## Step 1: Define The Facade

Create `kernel/src/arch.zig`.

Solution:

```zig
const builtin = @import("builtin");

const current = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("unsupported kernel architecture"),
};

pub fn initEarlyDebug() void {
    current.initEarlyDebug();
}

pub fn writeEarlyDebug(message: []const u8) void {
    current.writeEarlyDebug(message);
}

pub fn halt() noreturn {
    current.halt();
}
```

This file is the only place that should switch on `builtin.cpu.arch` for these
operations. If another shared module needs early debug output or halt behavior,
it imports `arch.zig`.

Checkpoint:

- `kernel/src/arch.zig` builds for x86_64 and aarch64.
- Unsupported architectures fail with a clear compile error.

## Step 2: Implement The x86_64 Module

Create or update `kernel/src/arch/x86_64.zig`.

Solution:

```zig
pub const io = @import("x86_64/io.zig");
pub const serial = @import("x86_64/serial.zig");

pub fn initEarlyDebug() void {
    serial.init();
}

pub fn writeEarlyDebug(message: []const u8) void {
    serial.writeString(message);
}

pub fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
```

This module is allowed to know about x86_64 details. It can import COM1 serial,
port I/O, and later x86_64 page table or interrupt code.

Checkpoint:

- x86_64 shared code can call `arch.writeEarlyDebug`.
- x86_64-specific code stays behind the x86_64 module boundary.

## Step 3: Implement The aarch64 Module

Create `kernel/src/arch/aarch64.zig`.

Solution:

```zig
pub fn initEarlyDebug() void {}

pub fn writeEarlyDebug(_: []const u8) void {}

pub fn halt() noreturn {
    asm volatile ("msr daifset, #0xf");
    while (true) {
        asm volatile ("wfi");
    }
}
```

The early debug functions are no-ops for now because this plan has not added an
aarch64 UART driver. The important part is that aarch64 implements the same API
as x86_64, so shared code does not need special cases.

Checkpoint:

- aarch64 still builds even though serial output is not implemented yet.
- Adding a UART driver later does not require changing `klog.zig` or
  `main.zig`.

## Step 4: Use The Facade In Shared Startup Code

Update `kernel/src/main.zig`.

Solution:

```zig
const arch = @import("arch.zig");
const limine = @import("limine");

export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();
    arch.writeEarlyDebug("zernel: booting\n");

    if (!base_revision.is_supported()) {
        arch.halt();
    }

    // Continue Limine response validation and framebuffer setup.
}
```

Then replace local architecture switches for halt behavior with:

```zig
fn hang() noreturn {
    arch.halt();
}
```

Checkpoint:

- `_start` has no direct import of `arch/x86_64.zig`.
- `_start` has no direct import of `arch/aarch64.zig`.
- Both targets still build.

## Step 5: Use The Facade In `klog`

Update `kernel/src/klog.zig`.

Solution:

```zig
const arch = @import("arch.zig");

fn line(level: []const u8, msg: []const u8) void {
    arch.writeEarlyDebug("[");
    arch.writeEarlyDebug(level);
    arch.writeEarlyDebug("] ");
    arch.writeEarlyDebug(msg);
    arch.writeEarlyDebug("\n");
}

pub fn info(msg: []const u8) void {
    line("info", msg);
}

pub fn warn(msg: []const u8) void {
    line("warn", msg);
}

pub fn err(msg: []const u8) void {
    line("err", msg);
}
```

`klog` should not import `arch/x86_64/serial.zig`. Logging is shared behavior;
serial is only one architecture's current debug transport.

Checkpoint:

- x86_64 logs go to COM1 serial.
- aarch64 logs compile and are discarded until a debug transport exists.
- `klog.zig` remains architecture-independent.

## Step 6: Decide What Belongs In The Facade

Only put operations in `arch.zig` when shared kernel code needs them.

Good facade candidates:

- `initEarlyDebug`.
- `writeEarlyDebug`.
- `halt`.
- Later: `disableInterrupts`, `enableInterrupts`, `readTimer`, `currentCpuId`.

Poor facade candidates:

- Raw x86_64 port I/O.
- x86_64 page table entry formats.
- aarch64 system register helpers.
- Driver-specific details.

The facade should expose kernel-level intent, not every CPU instruction.

Checkpoint:

- Shared modules import `arch.zig`.
- Architecture modules import their own low-level helpers.
- Low-level helpers are not pulled into unrelated targets.

## Done When

- `kernel/src/arch.zig` selects the current architecture once.
- Every supported architecture implements the same small API.
- `main.zig` and `klog.zig` import `arch.zig`, not x86_64-specific files.
- `make kernel-x86_64` and `make kernel-aarch64` both pass.

