# Plan 11: Input Roadmap

## Goal

Define how kernel input should evolve after the serial monitor exists.

The immediate goal is not a full input subsystem. The kernel only has one real
input source today: polled serial bytes through early debug I/O. This plan keeps
that path simple and reliable before introducing keyboard input, input events,
or richer interaction surfaces.

## Why This Comes Next

The serial monitor proves that the kernel can receive input and dispatch
commands. The next temptation is to generalize immediately into keyboard events,
terminal abstractions, or a shell. That would add unnecessary structure before
there is a second input source.

The next input work should:

- make serial monitor input reliable in QEMU;
- keep the architecture facade as the current polling boundary;
- split interaction code only when responsibilities are real;
- defer keyboard support until interrupt and device handling are ready;
- leave room for a future input event layer without inventing it too early.

## Current Input Shape

```text
kernel/src/arch/x86_64/serial.zig
  canRead
  readByte

kernel/src/arch/x86_64.zig
  readEarlyDebug

kernel/src/arch.zig
  readEarlyDebug

kernel/src/interaction/monitor.zig
  readInputByte
  echoByte
  readLine
  dispatch
  run
```

The monitor does not import architecture-specific serial code directly. It calls
`arch.readEarlyDebug()` and `arch.writeEarlyDebug()` through the facade.

## Stage 1: Stabilize Serial Monitor Input

Keep the first input path byte-oriented and polling-based.

Work to do:

- handle `\r` and `\n` consistently as Enter;
- echo printable characters;
- echo backspace in a way that updates the serial terminal visibly;
- ignore unsupported control bytes;
- keep the fixed line buffer bounded;
- avoid dynamic allocation;
- keep command dispatch read-only except for explicit commands like `halt`.

The monitor can continue to use local helpers:

```zig
fn readInputByte() ?u8 {
    return arch.readEarlyDebug();
}

fn echoByte(byte: u8) void {
    arch.writeEarlyDebug(&.{byte});
}
```

Implementation in `kernel/src/interaction/monitor.zig`:

```zig
fn isPrintable(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}

fn erasePreviousByte() void {
    arch.writeEarlyDebug(&.{ 8, ' ', 8 });
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
                if (len > 0) {
                    len -= 1;
                    erasePreviousByte();
                }
            },
            else => {
                if (isPrintable(byte) and len < buffer.len) {
                    buffer[len] = byte;
                    len += 1;
                    echoByte(byte);
                }
            },
        }
    }
}
```

Checkpoint:

- Typing in the QEMU serial terminal behaves predictably.
- Backspace edits the current line.
- Pressing Enter dispatches exactly one command.
- Invalid or empty input does not corrupt the prompt.

## Stage 2: Split Interaction Helpers Only When Needed

Keep `interaction/monitor.zig` as the orchestration point while the code is
small. Split files only when the responsibilities become stable.

Concrete split once `monitor.zig` grows beyond orchestration:

```text
kernel/src/interaction/monitor.zig
  monitor loop and high-level orchestration

kernel/src/interaction/line.zig
  fixed-buffer line input and editing

kernel/src/interaction/command.zig
  command matching, argument parsing, and dispatch helpers
```

Concrete move when this split happens:

```zig
// kernel/src/interaction/line.zig
pub const max_line = 128;

pub const Reader = struct {
    buffer: [max_line]u8 = undefined,

    pub fn read(self: *Reader) []const u8;
};

// kernel/src/interaction/command.zig
pub fn equals(a: []const u8, b: []const u8) bool;
```

Then `monitor.zig` keeps only:

```zig
var reader: line.Reader = .{};
const input = reader.read();
dispatch(info, input);
```

Do not move a tiny `equals` helper into `utils` just because it exists. Keep it
local until multiple unrelated subsystems need string helpers. If command
matching grows, move it to `interaction/command.zig`; if string operations
become broadly shared, then consider `kernel/src/utils/string.zig`.

Checkpoint:

- `monitor.zig` remains easy to read.
- line editing can be tested or inspected independently.
- command dispatch no longer mixes parsing details into the monitor loop.

## Stage 3: Add An Input Abstraction When There Is A Second Source

Do not introduce `interaction/input.zig` until the kernel has at least two input
sources to unify, such as serial and keyboard.

Concrete event shape once a second input source exists:

```zig
pub const Source = enum {
    early_debug,
    keyboard,
};

pub const Event = union(enum) {
    byte: u8,
    key: Key,
};
```

Concrete file once keyboard exists:

```text
kernel/src/interaction/input.zig
  Source
  Key
  Event
  poll
```

`poll` can keep serial as the first source:

```zig
pub fn poll() ?Event {
    if (arch.readEarlyDebug()) |byte| {
        return .{ .byte = byte };
    }
    return null;
}
```

That layer should represent input events. It should not own the serial driver,
keyboard driver, monitor commands, or framebuffer console.

Checkpoint:

- serial bytes and keyboard events can feed the same interaction code;
- the monitor can remain transport-neutral;
- architecture and device drivers still own hardware details.

## Stage 4: Keyboard Comes Later

Keyboard input should wait until the kernel has stronger interrupt and device
structure.

PS/2 keyboard support needs:

- interrupt controller setup;
- IRQ handling;
- scancode reading;
- scancode-to-key decoding;
- modifier state;
- a way to deliver events into `interaction`.

Keyboard input should feed the same interaction layer rather than replacing the
serial monitor. Serial should remain the lowest-friction debugging path.

Implementation boundary:

```text
kernel/src/arch/x86_64/keyboard.zig
  readScancode
  decode

kernel/src/interaction/input.zig
  converts decoded keys into interaction events
```

The keyboard driver owns hardware and scancode details. `interaction` owns only
the event shape and how monitor input consumes it.

## Verification

Each input stage should keep the kernel build green:

```text
make kernel-x86_64
```

When `line.zig`, `command.zig`, or `input.zig` appears, add host tests for pure
logic:

```text
zig test kernel/src/interaction/command.zig
zig test kernel/src/interaction/line.zig
zig test kernel/src/interaction/input.zig
```

## Non-Goals

- No terminal emulator.
- No user shell.
- No command history.
- No keyboard implementation in this step.
- No input event framework until there is more than one input source.
- No dynamic allocation.

## Done When

- The serial monitor input path is predictable and bounded.
- Interaction code has a clear split point for line editing and command
  dispatch.
- The architecture facade remains the boundary for early serial input.
- The plan for future keyboard input is documented without forcing it into the
  current monitor implementation.
