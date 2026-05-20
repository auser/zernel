# Plan 02: Limine Boot Info

## Goal

Collect and validate the boot information Limine gives us before we start
managing memory or changing page tables.

This turns Limine responses into a small internal boot context that later
subsystems can use without reaching directly into global Limine request objects.

## Why This Comes Next

The next code needs trustworthy facts about the machine before it can manage
memory or inspect page tables. Limine already knows where usable RAM is, how the
kernel was loaded, where the framebuffer lives, and how physical memory is
direct-mapped. If every subsystem reads raw Limine globals directly, boot
assumptions spread through the kernel and become hard to validate.

`BootInfo` is needed for:

- initializing the PMM from the firmware memory map;
- converting physical addresses through the HHDM safely;
- validating framebuffer assumptions before drawing or text rendering;
- locating the kernel's physical and virtual base addresses;
- giving later memory-plane and object metadata code a single source of boot
  truth.

## What We Will Build

- Limine requests for memory map, HHDM, kernel address, and stack size if needed.
- A `BootInfo` structure owned by the kernel.
- Serial logs that summarize the boot environment.
- Validation that panics early when required boot data is missing.

## Concepts To Understand First

- Limine request and response objects.
- The memory map and its entry types.
- Higher-half direct map, usually called HHDM.
- Physical versus virtual addresses.
- Why bootloader data should be copied or wrapped before broad kernel use.

### What HHDM Is

HHDM means higher-half direct map.

It is a virtual address window where physical RAM is mapped at a fixed offset.
Instead of treating a physical address as a pointer directly, the kernel adds
Limine's HHDM offset and gets a virtual address it can dereference.

Example:

```text
hhdm_offset = 0xffff800000000000
physical    = 0x0000000000100000
virtual     = 0xffff800000100000
```

The word "direct" means the mapping preserves the physical layout. Physical
address `0x1000` appears at `hhdm_offset + 0x1000`, physical address `0x2000`
appears at `hhdm_offset + 0x2000`, and so on.

The word "higher-half" means the virtual addresses live high in the address
space, away from low identity-mapped addresses and future user-space ranges.

HHDM is useful because Zig pointers are virtual addresses. If the PMM returns a
physical page frame such as `0x12345000`, kernel code cannot safely do this:

```zig
const ptr: *u8 = @ptrFromInt(0x12345000);
```

That number is a physical address. To access the same RAM through the direct
map, use:

```zig
const virt = boot_info.physToHhdm(&info, 0x12345000);
const ptr: *u8 = @ptrFromInt(virt);
```

HHDM does not make memory safe or allocatable by itself. It only gives the
kernel a convenient virtual route to physical memory that Limine already mapped.
The PMM still decides which physical frames are free, and page-table code still
decides what additional mappings should exist.

## Function Map

The boot-info path has three layers:

```text
main.zig
  _start()
    boot_info.base_revision.is_supported()
    boot_info.load()
    boot_info.validate(&info)
    boot_info.logFramebuffer(&info)
    boot_info.logMemoryMap(&info)
    boot_info.logAddressInfo(&info)
    paint(info.framebuffer)

boot/info.zig
  exported Limine request globals
  BootInfo
  load()
  validate()
  logFramebuffer()
  logMemoryMap()
  logAddressInfo()
  physToHhdm()
  hhdmToPhys()

klog.zig
  info()
  err()
  hex()
  dec()
  labelHex()
  labelDec()
```

Here is what each function is for:

| Function | File | Purpose |
| --- | --- | --- |
| `_start` | `main.zig` | Owns the boot sequence. It initializes logging, checks Limine support, loads boot info, validates it, logs it, and continues into kernel work. |
| `boot_info.load` | `boot/info.zig` | Converts raw Limine responses into one kernel-owned `BootInfo` value. It panics if required responses are missing. |
| `boot_info.validate` | `boot/info.zig` | Checks assumptions the rest of the kernel relies on, such as 32-bit framebuffer pixels and a non-empty memory map. |
| `boot_info.logFramebuffer` | `boot/info.zig` | Prints framebuffer metadata so we can confirm what Limine gave us. |
| `boot_info.logMemoryMap` | `boot/info.zig` | Prints memory ranges and computes useful totals from usable ranges. |
| `boot_info.logAddressInfo` | `boot/info.zig` | Prints HHDM and kernel physical/virtual base addresses. |
| `boot_info.physToHhdm` | `boot/info.zig` | Converts a physical address into its direct-map virtual address. |
| `boot_info.hhdmToPhys` | `boot/info.zig` | Converts a direct-map virtual address back into a physical address. |
| `klog.hex` | `klog.zig` | Writes a number as hexadecimal without heap allocation. Useful for addresses. |
| `klog.dec` | `klog.zig` | Writes a number as decimal without heap allocation. Useful for sizes and counts. |
| `klog.labelHex` | `klog.zig` | Writes `label: 0x...`. |
| `klog.labelDec` | `klog.zig` | Writes `label: ...`. |

The important dependency direction is:

```text
main.zig -> boot/info.zig -> klog.zig -> arch.zig
```

`boot/info.zig` may know about Limine. Later memory managers should receive
`*const BootInfo` or specific values from it rather than reaching back into
Limine request globals.

## Math Notes

### Memory Ranges

A Limine memory map entry gives:

```text
base   = first physical address in the range
length = number of bytes in the range
end    = base + length
```

The range covers addresses:

```text
[base, end)
```

That means `base` is included and `end` is excluded. This half-open interval is
common in systems code because its size is exactly `end - base`.

When we compute the highest usable physical address, we compare `end` values:

Expression used in `kernel/src/boot/info.zig` and later PMM code:

```zig
const end = base + length;
if (end > highest_usable) highest_usable = end;
```

### Usable Memory Totals

Only entries with `entry.kind == .usable` should be counted as allocatable
memory:

Expression used in `kernel/src/boot/info.zig` and later PMM code:

```zig
if (entry.kind == .usable) {
    usable_total += length;
    usable_ranges += 1;
}
```

Reserved, framebuffer, kernel/module, and bootloader ranges must not be handed
out by a future physical memory allocator.

### HHDM Translation Math

Limine maps physical memory into the HHDM virtual address window by adding one
fixed offset:

```text
hhdm_virtual = hhdm_offset + physical
physical     = hhdm_virtual - hhdm_offset
```

So the helper functions are just arithmetic:

File: `kernel/src/boot/info.zig`

```zig
pub fn physToHhdm(info: *const BootInfo, phys: usize) usize {
    return info.hhdm_offset + phys;
}

pub fn hhdmToPhys(info: *const BootInfo, virt: usize) usize {
    return virt - info.hhdm_offset;
}
```

These helpers do not create mappings. They only use the mapping Limine already
created.

### Hex Digits

Hexadecimal uses 4 bits per digit. To print a `usize` as hex, `klog.hex` walks
from the highest nibble to the lowest nibble:

```text
nibble = (value >> shift) & 0xf
```

`0xf` keeps only the low 4 bits after shifting. Values 0 through 9 become
`'0'` through `'9'`; values 10 through 15 become `'a'` through `'f'`.

### Decimal Digits

Decimal printing works in reverse. Repeatedly taking `value % 10` gives the
last digit. Repeatedly dividing by 10 removes the last digit:

```text
digit = value % 10
value = value / 10
```

Because that discovers digits from right to left, the helper fills a stack
buffer backward and then writes the final slice.

## Step 1: Add Limine Requests

Add request globals for:

- Memory map.
- HHDM.
- Kernel address.

Possible later requests:

- RSDP for ACPI.
- SMP information.
- Boot time.

Solution:

Put the Limine request globals in `kernel/src/boot/info.zig`, next to the
`BootInfo` type that consumes them. This keeps all Limine boot-info plumbing in
one boot module while keeping `main.zig` focused on boot flow.

File: `kernel/src/boot/info.zig`

```zig
const limine = @import("limine");

pub export var base_revision: limine.BaseRevision linksection(".limine_requests") = .{
    .revision = 3,
};

pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};
pub export var memory_map_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
pub export var kernel_address_request: limine.KernelAddressRequest linksection(".limine_requests") = .{};
```

Keep the request objects exported and in `.limine_requests`, just like the
framebuffer request. Limine discovers them by scanning that section.

Then `main.zig` imports `boot/info.zig` instead of owning the request globals:

File: `kernel/src/main.zig`

```zig
const boot_info = @import("boot/info.zig");

export fn _start() callconv(.c) noreturn {
    if (!boot_info.base_revision.is_supported()) {
        panic("unsupported Limine base revision");
    }

    // ...
}
```

The goal is to keep `_start` focused on boot flow. The Limine-specific global
request declarations live together in one place.

Checkpoint:

- Kernel builds.
- `_start` verifies each required response exists.

## Step 2: Define `BootInfo`

Create a kernel-owned structure that contains only the fields we actually need.

Start with:

- Framebuffer pointer or basic framebuffer metadata.
- Memory map response pointer.
- HHDM offset.
- Kernel physical base.
- Kernel virtual base.

Solution:

Create `kernel/src/boot/info.zig`:

File: `kernel/src/boot/info.zig`

```zig
const limine = @import("limine");

pub const BootInfo = struct {
    framebuffer: *limine.Framebuffer,
    memory_map: *limine.MemoryMapResponse,
    hhdm_offset: usize,
    kernel_physical_base: usize,
    kernel_virtual_base: usize,
};
```

Then create the builder function in the same file as `BootInfo`. This is the
ownership boundary:

- `boot/info.zig` owns Limine request globals, the kernel-friendly `BootInfo`
  type, and the `load()` function.
- `main.zig` owns the boot flow and should just call `boot_info.load()`.

File: `kernel/src/boot/info.zig`

```zig
const panic = @import("../panic.zig").panic;

pub fn load() BootInfo {
    const framebuffer_response =
        framebuffer_request.response orelse
        panic("missing framebuffer response");

    if (framebuffer_response.framebuffer_count == 0) {
        panic("no framebuffers available");
    }

    const memory_map = memory_map_request.response orelse panic("missing memory map");
    const hhdm = hhdm_request.response orelse panic("missing hhdm");
    const kernel_address =
        kernel_address_request.response orelse
        panic("missing kernel address");

    return .{
        .framebuffer = framebuffer_response.framebuffers()[0],
        .memory_map = memory_map,
        .hhdm_offset = @intCast(hhdm.offset),
        .kernel_physical_base = @intCast(kernel_address.physical_base),
        .kernel_virtual_base = @intCast(kernel_address.virtual_base),
    };
}
```

Then `main.zig` uses it:

File: `kernel/src/main.zig`

```zig
const boot_info = @import("boot/info.zig");

export fn _start() callconv(.c) noreturn {
    // Early debug and base revision validation...

    const info = boot_info.load();
    if (info.framebuffer.bpp != 32) {
        panic("unsupported framebuffer format");
    }

    paint(info.framebuffer);
    arch.halt();
}
```

The exact field names may need small adjustment depending on the Limine Zig
package version. Let compiler errors guide the final spelling.

Checkpoint:

- `_start` creates `BootInfo` once.
- Later setup functions receive `*const BootInfo` instead of reading Limine
  globals directly.

## Step 3: Log Framebuffer Details

Print:

- Width.
- Height.
- Pitch.
- Bits per pixel.
- Address.

Solution:

Put `logFramebuffer` in `kernel/src/boot/info.zig`, next to `BootInfo` and
`load()`. It logs boot-provided framebuffer metadata, so it belongs with the
boot-info module. `klog` remains the output mechanism.

First add small integer output helpers to `klog.zig`:

File: `kernel/src/klog.zig`

```zig
const arch = @import("arch.zig");

pub fn hex(value: usize) void {
    var buffer: [2 + @sizeOf(usize) * 2]u8 = undefined;
    buffer[0] = '0';
    buffer[1] = 'x';

    var index: usize = 2;
    var shift: usize = @bitSizeOf(usize);
    var started = false;
    while (shift > 0) {
        shift -= 4;
        const nibble: u8 = @intCast((value >> @intCast(shift)) & 0xf);
        if (nibble != 0 or started or shift == 0) {
            started = true;
            buffer[index] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
            index += 1;
        }
    }

    arch.writeEarlyDebug(buffer[0..index]);
}

pub fn dec(value: usize) void {
    var buffer: [@sizeOf(usize) * 3]u8 = undefined;
    var index = buffer.len;
    var remaining = value;

    if (remaining == 0) {
        arch.writeEarlyDebug("0");
        return;
    }

    while (remaining > 0) {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }

    arch.writeEarlyDebug(buffer[index..]);
}

pub fn labelDec(label: []const u8, value: usize) void {
    arch.writeEarlyDebug(label);
    arch.writeEarlyDebug(": ");
    dec(value);
    arch.writeEarlyDebug("\n");
}

pub fn labelHex(label: []const u8, value: usize) void {
    arch.writeEarlyDebug(label);
    arch.writeEarlyDebug(": ");
    hex(value);
    arch.writeEarlyDebug("\n");
}
```

These helpers still avoid heap allocation. They write digits into small stack
buffers and send the final slice through `arch.writeEarlyDebug`, keeping `klog`
architecture-independent.

Why the hex helper shifts by 4:

- One hex digit represents 4 bits.
- `value >> shift` moves the nibble we want into the low bits.
- `& 0xf` keeps only that nibble.
- Leading zero nibbles are skipped until the first non-zero nibble, except that
  the value `0` still prints as `0x0`.

Why the decimal helper fills the buffer backward:

- `remaining % 10` gives the last decimal digit.
- `remaining /= 10` removes that last digit.
- The digits arrive in reverse order, so the buffer is filled from the end
  toward the front.

Then log the framebuffer from `boot/info.zig`:

File: `kernel/src/boot/info.zig`

```zig
const klog = @import("../klog.zig");

pub fn logFramebuffer(info: *const BootInfo) void {
    const fb = info.framebuffer;

    klog.info("framebuffer");
    klog.labelDec("  width", @intCast(fb.width));
    klog.labelDec("  height", @intCast(fb.height));
    klog.labelDec("  pitch", @intCast(fb.pitch));
    klog.labelDec("  bpp", @intCast(fb.bpp));
    klog.labelHex("  address", @intFromPtr(fb.address));
}
```

Then call it from `_start` after `boot_info.load()` and framebuffer validation:

File: `kernel/src/main.zig`

```zig
const info = boot_info.load();
if (info.framebuffer.bpp != 32) {
    panic("unsupported framebuffer format");
}

boot_info.logFramebuffer(&info);
```

It is fine to implement `labelDec` and `labelHex` as simple serial-writing
helpers instead of a full formatter.

Why these framebuffer fields matter:

- `width` and `height` tell us the visible pixel dimensions.
- `pitch` tells us how many bytes each framebuffer row occupies in memory. It
  can be larger than `width * bytes_per_pixel` because firmware may pad rows for
  alignment.
- `bpp` tells us how many bits each pixel uses. This plan expects 32 bpp because
  the current paint code writes `u32` pixels.
- `address` is the virtual address where the kernel can write framebuffer
  pixels.

Checkpoint:

- Serial output matches the visible QEMU framebuffer.

## Step 4: Log Memory Map Summary

Print every memory map entry:

- Base address.
- Length.
- Type.

Also print summary totals:

- Total usable memory.
- Number of usable ranges.
- Highest usable physical address.

Solution:

Put `logMemoryMap` in `kernel/src/boot/info.zig`, next to
`logFramebuffer`. It is another view of boot-provided metadata.

File: `kernel/src/boot/info.zig`

```zig
pub fn logMemoryMap(info: *const BootInfo) void {
    var usable_total: usize = 0;
    var usable_ranges: usize = 0;
    var highest_usable: usize = 0;

    klog.info("memory map");

    for (info.memory_map.entries()) |entry| {
        const base: usize = @intCast(entry.base);
        const length: usize = @intCast(entry.length);
        const end = base + length;

        klog.labelHex("  base", base);
        klog.labelHex("  length", length);
        klog.labelDec("  kind", @intFromEnum(entry.kind));

        if (entry.kind == .usable) {
            usable_total += length;
            usable_ranges += 1;
            if (end > highest_usable) highest_usable = end;
        }
    }

    klog.labelDec("usable ranges", usable_ranges);
    klog.labelHex("usable bytes", usable_total);
    klog.labelHex("highest usable", highest_usable);
}
```

The Limine Zig package used here names the entry type field `kind`, so this code
uses `entry.kind`. If a future Limine binding names it differently, let the
compiler guide the small spelling fix.

The memory map math is:

```text
end = base + length
```

Each entry describes the half-open physical address range `[base, end)`. Usable
totals only include ranges where `entry.kind == .usable`; every other kind is
reserved for firmware, the bootloader, the framebuffer, the kernel, or broken
memory.

Then call it from `_start` after logging the framebuffer:

File: `kernel/src/main.zig`

```zig
boot_info.logFramebuffer(&info);
boot_info.logMemoryMap(&info);
```

Checkpoint:

- Logs are readable.
- Usable ranges are clearly distinguishable from reserved, bootloader,
  framebuffer, and kernel/module ranges.

## Step 5: Log HHDM And Kernel Address Info

Print:

- HHDM offset.
- Kernel physical base.
- Kernel virtual base.

Then add helper functions:

- `physToHhdm(phys: usize) usize`.
- `hhdmToPhys(virt: usize) usize`.

Solution:

Put the helpers next to `BootInfo`:

File: `kernel/src/boot/info.zig`

```zig
pub fn physToHhdm(info: *const BootInfo, phys: usize) usize {
    return info.hhdm_offset + phys;
}

pub fn hhdmToPhys(info: *const BootInfo, virt: usize) usize {
    return virt - info.hhdm_offset;
}
```

Then log:

File: `kernel/src/boot/info.zig`

```zig
pub fn logAddressInfo(info: *const BootInfo) void {
    klog.info("address info");
    klog.labelHex("  hhdm offset", info.hhdm_offset);
    klog.labelHex("  kernel physical", info.kernel_physical_base);
    klog.labelHex("  kernel virtual", info.kernel_virtual_base);
}
```

Then call it from `_start` after the other boot-info logs:

File: `kernel/src/main.zig`

```zig
boot_info.logFramebuffer(&info);
boot_info.logMemoryMap(&info);
boot_info.logAddressInfo(&info);
```

Do not dereference HHDM addresses yet. This step is only about establishing the
translation convention.

The HHDM math is:

```text
virtual = hhdm_offset + physical
physical = virtual - hhdm_offset
```

This works because Limine creates a direct virtual mapping of physical memory at
one fixed offset. These helpers are address conversions; they do not allocate
memory and they do not edit page tables.

Checkpoint:

- The helpers are simple arithmetic and do not touch page tables.
- Logs make it clear which addresses are physical and which are virtual.

## Step 6: Centralize Boot Validation

Create one function that validates required boot data and panics with clear
messages if something is missing.

Solution:

Keep `_start` small:

File: `kernel/src/main.zig`

```zig
const arch = @import("arch.zig");
const boot_info = @import("boot/info.zig");
const klog = @import("klog.zig");
const panic = @import("panic.zig").panic;

export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();
    klog.info("zernel: booting");
    klog.info("serial initialized");

    if (!boot_info.base_revision.is_supported()) {
        panic("unsupported Limine base revision");
    }

    const info = boot_info.load();
    boot_info.validate(&info);
    boot_info.logFramebuffer(&info);
    boot_info.logMemoryMap(&info);
    boot_info.logAddressInfo(&info);

    paint(info.framebuffer);
    arch.halt();
}
```

In this layout, `main.zig` owns the sequence, while `boot/info.zig` owns the
details:

- `boot_info.load()` reads Limine responses and builds `BootInfo`.
- `boot_info.validate(&info)` checks invariants the rest of the kernel assumes.
- `boot_info.logFramebuffer(&info)` logs framebuffer metadata.
- `boot_info.logMemoryMap(&info)` logs memory map metadata.
- `boot_info.logAddressInfo(&info)` logs HHDM and kernel address metadata.

`validate` should check:

File: `kernel/src/boot/info.zig`

```zig
pub fn validate(info: *const BootInfo) void {
    if (info.framebuffer.bpp != 32) {
        panic("unsupported framebuffer format");
    }

    if (@intFromPtr(info.framebuffer.address) == 0) {
        panic("framebuffer address is null");
    }

    if (info.memory_map.entry_count == 0) {
        panic("memory map is empty");
    }

    if (info.hhdm_offset == 0) {
        panic("missing hhdm offset");
    }

    if (info.kernel_physical_base == 0) {
        panic("missing kernel physical base");
    }

    if (info.kernel_virtual_base == 0) {
        panic("missing kernel virtual base");
    }
}
```

With this in place, `main.zig` should not repeat the framebuffer `bpp` check.
The boot-info module owns validation of boot-info invariants.

Checkpoint:

- Removing a required request temporarily produces a readable panic.
- Normal boot prints a concise success line after validation.

## Done When

- The kernel has a clear `BootInfo` structure.
- Serial logs show framebuffer, memory map, HHDM, and kernel address data.
- Missing required Limine responses fail through the kernel panic path.
