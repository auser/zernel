# Plan 07: Serial Kernel Monitor

## Goal

Add the first interactive interface: a tiny command monitor over the serial
port.

This is not a user shell, process runtime, or terminal emulator. It is a kernel
debug monitor that lets us inspect state and trigger small diagnostics while the
kernel is still single-tasked.

## Why This Comes Next

The next code needs interaction before keyboard interrupts, filesystems, user
mode, or networking exist. QEMU serial input is the lowest-friction path because
we already have serial output from Plan 01 and can poll the COM1 status register
without enabling external IRQs.

The serial monitor is needed for:

- confirming the kernel can receive input, not just print output;
- inspecting boot info, memory state, and framebuffer state on demand;
- testing future object, capability, cell, and route registries interactively;
- avoiding a premature keyboard/PIC/APIC dependency;
- creating a practical debugging loop before real userland exists.

## What We Will Build

- A serial input polling function for x86_64.
- A tiny line editor for serial input.
- A command dispatcher.
- A few read-only commands:
  - `help`
  - `boot`
  - `mem`
  - `fb`
  - `clear`
  - `halt`
- A monitor loop entered after boot diagnostics.

## How This Code Gets Used

After the kernel initializes logging, boot info, memory, exceptions, and the
framebuffer console, it can enter the monitor instead of immediately halting:

```text
main.zig
  boot diagnostics
  console init
  monitor.run(&info)
    prompt
    read line from serial
    dispatch command
    print through klog
```

The monitor should write through `klog`, so output appears on serial and on the
framebuffer console when available.

## Proposed Layout

Place the first monitor implementation under `kernel/src/interaction/`:

```text
kernel/src/interaction/monitor.zig
  run
  readLine
  dispatch
```

The monitor is a debugging tool today, but its architectural role is the first
kernel interaction surface. Keeping it under `interaction` leaves room for
future serial, keyboard, command, and line-editing code without mixing those
entry points into architecture code, framebuffer code, or generic utilities.

Keep the initial version in one file. Split it only when the responsibilities
become real:

```text
kernel/src/interaction/line.zig
  fixed-buffer line input and editing

kernel/src/interaction/command.zig
  command matching and dispatch helpers

kernel/src/interaction/serial.zig
  serial-backed monitor frontend
```

The inspected systems should stay in their own directories. For example, memory
state stays under `mem`, framebuffer code stays under `fb`, and future objects,
capabilities, cells, and routes stay under `core`. Interaction code should call
those systems and format responses, not own their state.

## Non-Goals

- No keyboard input.
- No external hardware IRQs.
- No task scheduling.
- No user mode.
- No filesystem commands.
- No command history beyond a single line buffer.
- No dynamic allocation.

## Concepts To Understand First

- Polling serial input versus interrupt-driven input.
- Line buffering.
- Command dispatch by fixed string comparisons.
- Why monitor commands should be read-only until the kernel has stronger
  recovery paths.

## Step 1: Add Serial Input Polling

Extend the x86_64 serial driver with non-blocking input.

Solution:

File: `kernel/src/arch/x86_64/serial.zig`

```zig
pub fn canRead() bool {
    return (io.inb(com1 + 5) & 1) != 0;
}

pub fn readByte() ?u8 {
    if (!canRead()) return null;
    return io.inb(com1);
}
```

Expose this through the architecture facade so `interaction/monitor.zig` does
not import `arch/x86_64/serial.zig` directly:

File: `kernel/src/arch/x86_64.zig`

```zig
pub fn readEarlyDebug() ?u8 {
    return serial.readByte();
}
```

File: `kernel/src/arch.zig`

```zig
pub fn readEarlyDebug() ?u8 {
    return current.readEarlyDebug();
}
```

Architectures without early debug input can return `null` until they grow a
real implementation:

File: `kernel/src/arch/aarch64.zig`

```zig
pub fn readEarlyDebug() ?u8 {
    return null;
}
```

Checkpoint:

- QEMU serial input can be detected without blocking forever.
- Existing serial output still works.

## Step 2: Add A Line Reader

Read one line into a fixed-size buffer.

Solution:

File: `kernel/src/interaction/monitor.zig`

```zig
const arch = @import("../arch.zig");
const boot_info = @import("../boot/info.zig");
const klog = @import("../utils/klog.zig");

const BootInfo = boot_info.BootInfo;
const max_line = 128;

fn readInputByte() ?u8 {
    return arch.readEarlyDebug();
}

fn echoByte(byte: u8) void {
    arch.writeEarlyDebug(&.{byte});
}

fn readLine(buffer: *[max_line]u8) []const u8 {
    var len: usize = 0;
    while (true) {
        const byte = readInputByte() orelse continue;
        switch (byte) {
            '\r', '\n' => {
                klog.info("");
                return buffer[0..len];
            },
            8, 127 => {
                if (len > 0) len -= 1;
            },
            else => {
                if (len < buffer.len) {
                    buffer[len] = byte;
                    len += 1;
                    echoByte(byte);
                }
            },
        }
    }
}
```

`readInputByte` and `echoByte` are monitor-local helpers. They keep the line
reader phrased in terms of interaction behavior while the architecture facade
owns the concrete serial polling and output.

Checkpoint:

- Typing in the QEMU serial terminal echoes characters.
- Pressing Enter returns a line to the monitor.

## Step 3: Dispatch Basic Commands

Start with fixed commands and no arguments.

Solution:

File: `kernel/src/interaction/monitor.zig`

```zig
fn dispatch(info: *const BootInfo, line: []const u8) void {
    if (equals(line, "help")) {
        klog.info("commands: help boot mem fb clear halt");
    } else if (equals(line, "boot")) {
        boot_info.logAddressInfo(info);
    } else if (equals(line, "mem")) {
        boot_info.logMemoryMap(info);
    } else if (equals(line, "fb")) {
        boot_info.logFramebuffer(info);
    } else if (equals(line, "clear")) {
        // Optional once framebuffer console exposes clear().
    } else if (equals(line, "halt")) {
        arch.halt();
    } else if (line.len != 0) {
        klog.warn("unknown command");
    }
}

fn equals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }

    return true;
}
```

Keep `equals` local to the monitor for now. Move command matching into
`interaction/command.zig` only when dispatch grows beyond a few fixed strings.

Checkpoint:

- `help` prints a command list.
- `boot`, `mem`, and `fb` reprint existing boot diagnostics.
- Unknown commands produce a readable warning.

## Step 4: Enter The Monitor Loop

Add the monitor after initialization work that should happen automatically.

Solution:

File: `kernel/src/main.zig`

```zig
const monitor = @import("interaction/monitor.zig");

monitor.run(&info);
arch.halt();
```

File: `kernel/src/interaction/monitor.zig`

```zig
pub fn run(info: *const BootInfo) noreturn {
    var buffer: [max_line]u8 = undefined;

    klog.info("monitor ready");
    while (true) {
        arch.writeEarlyDebug("> ");
        const line = readLine(&buffer);
        dispatch(info, line);
    }
}
```

The monitor loop is `noreturn`, so the halt after `monitor.run(&info)` is only a
defensive fallback if the implementation is later changed to return.

Checkpoint:

- The kernel boots to a prompt.
- Commands can be typed over serial.
- The framebuffer still shows logs when the console is initialized.

## Done When

- The kernel has an interactive serial prompt.
- Read-only diagnostic commands work.
- The monitor does not require keyboard interrupts or dynamic allocation.
