# Plan 01: Early Serial Logging

## Goal

Make the kernel talk to us through QEMU.

At the previous milestone, the kernel could boot through Limine and draw a
framebuffer gradient. That proves a lot: the ELF loaded, `_start` ran, Limine
gave us a framebuffer, and our kernel wrote pixels. But it is still a poor
debugging workflow. If the screen stays black, we do not know whether the kernel
never started, Limine did not give us a framebuffer, our drawing code broke, or
we halted before painting.

Serial logging fixes that. On x86_64, QEMU can expose the old COM1 serial port
as terminal output. The kernel writes bytes to COM1, and we see text in the
terminal running QEMU.

This is the first real debugging tool we add to the kernel.

## Why This Comes Next

The next code needs a dependable way to report progress before the framebuffer
console, allocator, interrupts, or page fault handler exist. A kernel that only
draws pixels can fail in too many silent ways: a missing Limine response, bad
address, unsupported framebuffer format, or early panic may all look like a
black screen.

Serial logging is needed for:

- confirming the CPU reached `_start`;
- reporting Limine validation failures before graphics code runs;
- making PMM and VM accounting visible during early boot;
- printing exception and page fault diagnostics later;
- giving future object, capability, cell, and route registries a simple debug
  dump path before richer tools exist.

## What We Will Build

- Tiny x86_64 port I/O helpers: `inb` and `outb`.
- A COM1 serial driver.
- Early boot messages from `_start`.
- A small `klog` API.
- A panic path that logs an error before halting.
- A QEMU debug workflow that shows serial output in the terminal.

## What This Assumes

Plan 00 introduced the architecture facade:

Example use inside shared kernel files: `kernel/src/main.zig`, `kernel/src/klog.zig`, `kernel/src/panic.zig`

```zig
const arch = @import("arch.zig");
```

Shared files such as `main.zig`, `klog.zig`, and `panic.zig` should use that
facade. x86_64-specific files can still use x86_64-specific instructions and
helpers.

That split is important for learning OS development in Zig:

- Shared kernel code expresses intent: "write debug text" or "halt".
- Architecture modules know how to do that on a specific CPU.
- The compiler selects the correct architecture module for the target.

## Function Map

Before writing code, it helps to know how the pieces relate. The serial logging
path is deliberately layered:

```text
main.zig
  _start()
    arch.initEarlyDebug()
      arch.zig
        current.initEarlyDebug()
          arch/x86_64.zig
            serial.init()
              arch/x86_64/serial.zig
                io.outb(...)
                  arch/x86_64/io.zig
                    x86_64 outb instruction

  _start()
    klog.info("zernel: booting")
      klog.zig
        arch.writeEarlyDebug(...)
          arch.zig
            current.writeEarlyDebug(...)
              arch/x86_64.zig
                serial.writeString(...)
                  serial.writeByte(...)
                    io.outb(com1, byte)
```

The panic path uses the same logging path, then halts through the facade:

```text
main.zig
  panic("missing framebuffer response")
    panic.zig
      klog.err("PANIC")
      klog.err(message)
      arch.halt()
        arch.zig
          current.halt()
            arch/x86_64.zig or arch/aarch64.zig
```

Here is the ownership model:

| Function | File | Job |
| --- | --- | --- |
| `_start` | `main.zig` | Kernel entry point. Starts early debug, validates boot data, then runs kernel setup. |
| `arch.initEarlyDebug` | `arch.zig` | Shared facade function. Initializes whatever early debug output exists for the current architecture. |
| `arch.writeEarlyDebug` | `arch.zig` | Shared facade function. Writes bytes to the current architecture's early debug output. |
| `arch.halt` | `arch.zig` | Shared facade function. Stops the CPU using the current architecture's halt loop. |
| `x86_64.initEarlyDebug` | `arch/x86_64.zig` | x86_64 implementation of early debug initialization. Calls COM1 serial init. |
| `x86_64.writeEarlyDebug` | `arch/x86_64.zig` | x86_64 implementation of early debug writes. Sends strings to COM1. |
| `serial.init` | `arch/x86_64/serial.zig` | Programs COM1 into a known serial mode. |
| `serial.writeByte` | `arch/x86_64/serial.zig` | Waits until COM1 can transmit, then writes one byte. |
| `serial.writeString` | `arch/x86_64/serial.zig` | Sends a string one byte at a time, converting `\n` to `\r\n`. |
| `io.inb` | `arch/x86_64/io.zig` | Reads one byte from an x86_64 I/O port. |
| `io.outb` | `arch/x86_64/io.zig` | Writes one byte to an x86_64 I/O port. |
| `klog.info` | `klog.zig` | Logs an informational line through `arch.writeEarlyDebug`. |
| `klog.warn` | `klog.zig` | Logs a warning line through `arch.writeEarlyDebug`. |
| `klog.err` | `klog.zig` | Logs an error line through `arch.writeEarlyDebug`. |
| `panic` | `panic.zig` | Logs a panic reason, then halts through `arch.halt`. |

The important rule is dependency direction:

```text
shared kernel code -> arch.zig -> architecture module -> low-level helpers
```

Shared code should not skip the facade and import `arch/x86_64/serial.zig`
directly. If it did, the shared file would stop being portable to aarch64.

## Concepts To Understand First

### Port I/O

x86_64 has an I/O port address space separate from normal memory. The `inb` and
`outb` instructions read and write one byte from an I/O port.

COM1 lives at port `0x3f8`. To send a byte over COM1, the kernel eventually
writes that byte to port `0x3f8`.

### Why Serial Before A Text Console

A framebuffer text console sounds friendlier, but it requires a font, glyph
rendering, cursor state, line wrapping, and scrolling. Serial output is much
smaller. It is exactly what we want before the kernel has a heap, interrupts, or
real memory management.

### Why No Allocation

Everything in this plan runs very early. We should not use heap allocation,
dynamic formatting, or standard library facilities that assume an operating
system exists. We will write fixed strings and small helper functions.

## Math Notes

### COM1 Register Offsets

COM1 starts at I/O port `0x3f8`. The serial controller exposes several
registers by adding small offsets to that base:

```text
base = 0x3f8
data register         = base + 0
interrupt enable      = base + 1
line control register = base + 3
line status register  = base + 5
```

That is why the code writes values such as `com1 + 1`, `com1 + 3`, and
`com1 + 5`. The `com1` constant is the base address; the offset selects the
register.

### Baud Divisor

The common PC serial clock is 115200 Hz. To get 38400 baud:

```text
divisor = 115200 / 38400 = 3
```

The divisor is split into low and high bytes. For divisor `3`:

```text
low byte  = 0x03
high byte = 0x00
```

That is why initialization writes:

```text
com1 + 0 = 0x03
com1 + 1 = 0x00
```

while divisor latch access is enabled.

### Transmit Ready Bit

The line status register lives at `com1 + 5`. Bit `0x20` means the transmit
holding register is empty:

```text
0x20 = 0b0010_0000
```

The check:

```text
(status & 0x20) != 0
```

keeps only that bit. If the result is non-zero, COM1 can accept another byte.

### Newline Conversion

Serial terminals commonly expect carriage return plus newline:

```text
\n  ->  \r\n
```

`\r` moves the cursor back to column zero. `\n` moves to the next line. Emitting
both keeps output readable in more terminals.

## Step 1: Add x86_64 Port I/O Helpers

Create `kernel/src/arch/x86_64/io.zig`.

This file is x86_64-only. It wraps the CPU instructions that talk to I/O ports.
No shared kernel file should import it directly.

Solution:

File: `kernel/src/arch/x86_64/io.zig`

```zig
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}
```

What to notice:

- `asm volatile` tells Zig this assembly has side effects and must not be
  optimized away.
- `port` is the I/O port number.
- `value` is the byte being read or written.
- The register constraints place the values where the x86_64 instructions
  expect them.

Checkpoint:

- `make kernel-x86_64` still builds.
- Shared code still does not import `arch/x86_64/io.zig`.

## Step 2: Initialize COM1

Create `kernel/src/arch/x86_64/serial.zig`.

This file knows about the COM1 register layout. COM1 starts at port `0x3f8`, and
the surrounding offsets configure baud rate, line format, FIFO behavior, and
modem control.

Solution:

File: `kernel/src/arch/x86_64/serial.zig`

```zig
const io = @import("io.zig");

const com1: u16 = 0x3f8;

pub fn init() void {
    io.outb(com1 + 1, 0x00); // Disable serial interrupts.
    io.outb(com1 + 3, 0x80); // Enable divisor latch access.
    io.outb(com1 + 0, 0x03); // Divisor low byte: 38400 baud.
    io.outb(com1 + 1, 0x00); // Divisor high byte.
    io.outb(com1 + 3, 0x03); // 8 data bits, no parity, one stop bit.
    io.outb(com1 + 2, 0xc7); // Enable and clear FIFO.
    io.outb(com1 + 4, 0x0b); // Mark data terminal ready/request to send.
}
```

Then expose serial through the x86_64 architecture module:

File: `kernel/src/arch/x86_64.zig`

```zig
pub const io = @import("x86_64/io.zig");
pub const serial = @import("x86_64/serial.zig");

pub fn initEarlyDebug() void {
    serial.init();
}
```

Because Plan 00 gave every architecture the same facade shape, shared startup
code can call:

File: `kernel/src/main.zig`

```zig
const arch = @import("arch.zig");

export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();

    // Continue boot validation...
}
```

On x86_64, this initializes COM1. On aarch64, it is currently a no-op until we
add a UART driver.

Checkpoint:

- `make kernel-x86_64` builds.
- `make kernel-aarch64` also builds.
- The framebuffer gradient still appears when running QEMU.

## Step 3: Write Bytes And Strings

Initialization prepares COM1. Now we need to send bytes.

Before writing a byte, the kernel should wait until COM1 says the transmit
buffer is empty. That status bit lives at `com1 + 5`, bit `0x20`.

Solution:

Add this to `kernel/src/arch/x86_64/serial.zig`:

File: `kernel/src/arch/x86_64/serial.zig`

```zig
fn canTransmit() bool {
    return (io.inb(com1 + 5) & 0x20) != 0;
}

pub fn writeByte(byte: u8) void {
    while (!canTransmit()) {}
    io.outb(com1, byte);
}

pub fn writeString(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') {
            writeByte('\r');
        }
        writeByte(byte);
    }
}
```

The `\r` before `\n` is for terminal compatibility. Many serial terminals
expect carriage return plus newline.

Then expose writing through `kernel/src/arch/x86_64.zig`:

File: `kernel/src/arch/x86_64.zig`

```zig
pub fn writeEarlyDebug(message: []const u8) void {
    serial.writeString(message);
}
```

Now shared code can print one early line:

File: `kernel/src/main.zig`

```zig
export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();
    arch.writeEarlyDebug("zernel: booting\n");

    // Continue boot validation...
}
```

Checkpoint:

- `make debug-x86_64` prints:

```text
zernel: booting
```

- The framebuffer gradient still appears.

## Step 4: Add `klog`

Direct calls to `arch.writeEarlyDebug` are useful for the first proof, but they
will get noisy. The rest of the kernel should log through one small API.

Create `kernel/src/klog.zig`.

Solution:

File: `kernel/src/klog.zig`

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

Important detail: `klog.zig` imports `arch.zig`, not
`arch/x86_64/serial.zig`. Logging is shared kernel behavior. COM1 serial is only
the current x86_64 transport for that behavior.

Update `_start` to use `klog`:

File: `kernel/src/main.zig`

```zig
const arch = @import("arch.zig");
const klog = @import("klog.zig");

export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();
    klog.info("zernel: booting");
    klog.info("serial initialized");

    // Continue boot validation...
}
```

Checkpoint:

- `make debug-x86_64` starts with:

```text
[info] zernel: booting
[info] serial initialized
```

- `make kernel-aarch64` still builds, even though aarch64 currently discards
  early debug output.

## Step 5: Add A Panic Path

So far, early failures call `halt`. That is silent. A panic path should print a
reason before stopping the CPU.

Create `kernel/src/panic.zig`.

Solution:

File: `kernel/src/panic.zig`

```zig
const arch = @import("arch.zig");
const klog = @import("klog.zig");

pub fn panic(msg: []const u8) noreturn {
    klog.err("PANIC");
    klog.err(msg);
    arch.halt();
}
```

Then use it in `kernel/src/main.zig`:

File: `kernel/src/main.zig`

```zig
const panic = @import("panic.zig").panic;

export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();
    klog.info("zernel: booting");
    klog.info("serial initialized");

    if (!base_revision.is_supported()) {
        panic("unsupported Limine base revision");
    }

    const response = framebuffer_request.response orelse
        panic("missing framebuffer response");

    if (response.framebuffer_count == 0) {
        panic("no framebuffers available");
    }

    const framebuffer = response.framebuffers()[0];
    if (framebuffer.bpp != 32) {
        panic("unsupported framebuffer format");
    }

    paint(framebuffer);
    arch.halt();
}
```

This is a small change, but it changes the workflow. Instead of guessing why the
kernel stopped, the terminal can tell us.

Later, after framebuffer state is stored somewhere global or passed into a
kernel context, `panic` can also paint the screen red. For this first version,
serial output is the important part.

Checkpoint:

- Temporarily force a panic after `arch.initEarlyDebug()`.
- QEMU prints:

```text
[err] PANIC
[err] your test message
```

- Remove the forced panic before moving on.

## Step 6: Use QEMU Serial Output

The Makefile debug target should route the guest serial port to the terminal.

The current shape is:

File: `Makefile`

```make
debug-x86_64: $(ISO_X86_64_FILE)
	qemu-system-x86_64 -M q35 -m 128M -cdrom $(ISO_X86_64_FILE) -boot d \
		-serial stdio -no-reboot -no-shutdown
```

What the flags mean:

- `-serial stdio` connects guest COM1 to your terminal.
- `-no-reboot` keeps QEMU from immediately rebooting on certain failures.
- `-no-shutdown` keeps the QEMU window/session around after shutdown-like
  events.

Run:

Command:

```sh
make debug-x86_64
```

Expected output:

```text
[info] zernel: booting
[info] serial initialized
```

Checkpoint:

- The terminal shows serial logs.
- The framebuffer gradient still appears.
- If you force a panic, the panic message appears in the terminal.

## Done When

- The kernel initializes COM1 on x86_64.
- The kernel can write serial text from `_start`.
- Shared code logs through `klog`.
- Startup failures call `panic`.
- `panic` logs a message and halts through `arch.halt`.
- `make kernel-x86_64` and `make kernel-aarch64` both build.
- `make debug-x86_64` shows serial output in the terminal.
