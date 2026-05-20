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
  readKeyboardKey

kernel/src/interaction/monitor.zig
  dispatch
  run

kernel/src/interaction/line.zig
  Reader
  readInputByte
  echoByte

kernel/src/interaction/command.zig
  equals

kernel/src/interaction/input.zig
  poll
```

The monitor does not import architecture-specific serial code directly. It calls
`arch.readEarlyDebug()` and `arch.writeEarlyDebug()` through the facade.

## Implementation Order

Implement this plan in stages and keep the files explicit:

```text
Stage 1:
  kernel/src/interaction/monitor.zig

Stage 2:
  kernel/src/interaction/line.zig
  kernel/src/interaction/command.zig
  kernel/src/interaction/monitor.zig

Stage 3:
  kernel/src/interaction/input.zig
  kernel/src/interaction/line.zig
  kernel/src/interaction/monitor.zig

Stage 4:
  kernel/src/arch/x86_64/keyboard.zig
  kernel/src/interaction/input.zig
```

Do not create the later files until their stage starts. Stage 1 intentionally
keeps input helpers local to `monitor.zig`.

## Stage 1: Stabilize Serial Monitor Input

Status: implemented in `kernel/src/interaction/monitor.zig`.

Keep the first input path byte-oriented and polling-based.

Work to do:

- handle `\r` and `\n` consistently as Enter;
- echo printable characters;
- echo backspace in a way that updates the serial terminal visibly;
- ignore unsupported control bytes;
- keep the fixed line buffer bounded;
- avoid dynamic allocation;
- keep command dispatch read-only except for explicit commands like `halt`.

File: `kernel/src/interaction/monitor.zig`

The monitor keeps these local helpers during Stage 1:

```zig
fn readInputByte() ?u8 {
    return arch.readEarlyDebug();
}

fn echoByte(byte: u8) void {
    arch.writeEarlyDebug(&.{byte});
}
```

Replace the current byte handling in `readLine` with printable filtering and
visible backspace erasure:

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

The Stage 1 `dispatch` implementation stays in the same file. It should keep
calling the existing monitor commands directly:

File: `kernel/src/interaction/monitor.zig`

```zig
fn dispatch(info: *const BootInfo, line: []const u8) void {
    if (equals(line, "help")) {
        klog.info("commands: help boot mem fb objects caps cells routes clear halt");
    } else if (equals(line, "boot")) {
        boot_info.logAddressInfo(info);
    } else if (equals(line, "mem")) {
        boot_info.logMemoryMap(info);
    } else if (equals(line, "fb")) {
        boot_info.logFramebuffer(info);
    } else if (equals(line, "objects")) {
        core.dumpObjects();
    } else if (equals(line, "caps")) {
        core.dumpCapabilities();
    } else if (equals(line, "cells")) {
        core.dumpCells();
    } else if (equals(line, "routes")) {
        core.dumpRoutes();
    } else if (equals(line, "halt")) {
        arch.halt();
    } else if (line.len != 0) {
        klog.warn("unknown command");
    }
}
```

Checkpoint:

- Typing in the QEMU serial terminal behaves predictably.
- Backspace edits the current line.
- Pressing Enter dispatches exactly one command.
- Invalid or empty input does not corrupt the prompt.

## Stage 2: Split Interaction Helpers Only When Needed

Status: implemented in `kernel/src/interaction/line.zig`,
`kernel/src/interaction/command.zig`, and `kernel/src/interaction/monitor.zig`.

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

File: `kernel/src/interaction/line.zig`

```zig
const input = @import("input.zig");

pub const max_line = 128;
pub const WriteFn = *const fn ([]const u8) void;

pub const Reader = struct {
    buffer: [max_line]u8 = undefined,
    read_byte: input.ReadByteFn,
    read_key: input.ReadKeyFn,
    write: WriteFn,

    pub fn init(read_byte: input.ReadByteFn, read_key: input.ReadKeyFn, write: WriteFn) Reader {
        return .{
            .read_byte = read_byte,
            .read_key = read_key,
            .write = write,
        };
    }

    pub fn read(self: *Reader) []const u8 {
        var len: usize = 0;
        while (true) {
            const byte = self.readInputByte() orelse continue;
            switch (byte) {
                '\r', '\n' => {
                    self.write("\n");
                    return self.buffer[0..len];
                },
                8, 127 => {
                    if (len > 0) {
                        len -= 1;
                        self.erasePreviousByte();
                    }
                },
                else => {
                    if (isPrintable(byte) and len < self.buffer.len) {
                        self.buffer[len] = byte;
                        len += 1;
                        self.echoByte(byte);
                    }
                },
            }
        }
    }

    fn readInputByte(self: *Reader) ?u8 {
        const event = input.poll(self.read_byte, self.read_key) orelse return null;
        return switch (event) {
            .byte => |byte| byte,
            .key => null,
        };
    }

    fn echoByte(self: *Reader, byte: u8) void {
        self.write(&.{byte});
    }

    fn erasePreviousByte(self: *Reader) void {
        self.write(&.{ 8, ' ', 8 });
    }
};
```

File: `kernel/src/interaction/line.zig`

```zig
fn isPrintable(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}
```

File: `kernel/src/interaction/command.zig`

```zig
pub fn equals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }

    return true;
}
```

File: `kernel/src/interaction/monitor.zig`

After the split, `monitor.zig` imports the helpers and keeps orchestration:

```zig
const command = @import("command.zig");
const input = @import("input.zig");
const line = @import("line.zig");

var reader = line.Reader.init(readEarlyDebug, readKeyboardKey, writeDebug);
const input_line = reader.read();
dispatch(info, input_line);
```

The dispatch checks then call `command.equals(...)` instead of local `equals`.
`monitor.zig` owns the small wrappers that adapt `arch.zig` to interaction
function pointers:

```zig
fn readEarlyDebug() ?u8 {
    return arch.readEarlyDebug();
}

fn readKeyboardKey() ?input.Key {
    const key = arch.readKeyboardKey() orelse return null;
    return .{ .code = key.code, .pressed = key.pressed };
}

fn writeDebug(bytes: []const u8) void {
    arch.writeEarlyDebug(bytes);
}
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

Status: implemented as an architecture-neutral polling layer in
`kernel/src/interaction/input.zig`.

Do not introduce `interaction/input.zig` until the kernel has at least two input
sources to unify, such as serial and keyboard.

File: `kernel/src/interaction/input.zig`

Concrete event shape once a second input source exists:

```zig
pub const Source = enum {
    early_debug,
    keyboard,
};

pub const Key = struct {
    code: u16,
    pressed: bool,
};

pub const Event = union(enum) {
    byte: u8,
    key: Key,
};
```

File: `kernel/src/interaction/input.zig`

`poll` keeps serial as the first source:

```zig
pub const ReadByteFn = *const fn () ?u8;
pub const ReadKeyFn = *const fn () ?Key;

pub fn poll(read_byte: ReadByteFn, read_key: ReadKeyFn) ?Event {
    if (read_byte()) |byte| {
        return .{ .byte = byte };
    }
    if (read_key()) |key| {
        return .{ .key = .{
            .code = key.code,
            .pressed = key.pressed,
        } };
    }
    return null;
}
```

File: `kernel/src/interaction/line.zig`

Once `input.zig` exists, the line reader consumes `input.poll(...)` through
function pointers supplied by `monitor.zig` instead of importing `arch.zig`
directly:

```zig
const input = @import("input.zig");

fn readInputByte(self: *Reader) ?u8 {
    const event = input.poll(self.read_byte, self.read_key) orelse return null;
    return switch (event) {
        .byte => |byte| byte,
        .key => null,
    };
}
```

`input.zig` represents input events. It does not own the serial driver, keyboard
driver, monitor commands, or framebuffer console.

Checkpoint:

- serial bytes and keyboard events can feed the same interaction code;
- the monitor can remain transport-neutral;
- architecture and device drivers still own hardware details.

## Stage 4: Keyboard Comes Later

Status: stubbed through the architecture facade. The x86_64 keyboard file
exists, but it returns no key events until the interrupt/device layer is ready.

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
kernel/src/arch.zig
  KeyboardKey
  readKeyboardKey

kernel/src/arch/x86_64.zig
  KeyboardKey
  readKeyboardKey

kernel/src/arch/aarch64.zig
  KeyboardKey
  readKeyboardKey

kernel/src/arch/x86_64/keyboard.zig
  DecodedKey
  readScancode
  decode

kernel/src/interaction/input.zig
  converts architecture keyboard keys into interaction events
```

The keyboard driver owns hardware and scancode details. `interaction` owns only
the event shape and how monitor input consumes it.

File: `kernel/src/arch/x86_64/keyboard.zig`

```zig
pub const DecodedKey = struct {
    code: u16,
    pressed: bool,
};

pub fn readScancode() ?u8 {
    return null;
}

pub fn decode(scancode: u8) ?DecodedKey {
    _ = scancode;
    return null;
}
```

File: `kernel/src/arch/x86_64.zig`

```zig
pub const keyboard = @import("x86_64/keyboard.zig");
pub const KeyboardKey = keyboard.DecodedKey;

pub fn readKeyboardKey() ?KeyboardKey {
    const scancode = keyboard.readScancode() orelse return null;
    return keyboard.decode(scancode);
}
```

File: `kernel/src/arch.zig`

```zig
pub const KeyboardKey = current.KeyboardKey;

pub fn readKeyboardKey() ?KeyboardKey {
    return current.readKeyboardKey();
}
```

## Verification

Each input stage should keep the kernel build green:

```text
make kernel-x86_64
```

When `line.zig`, `command.zig`, or `input.zig` appears, add host tests for pure
logic. Interaction modules import files outside their own directory, so test
them through the package-root aggregator:

```text
cd kernel && zig test src/interaction/tests.zig
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
