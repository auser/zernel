# Plan 03: Physical Memory Manager

## Goal

Use the Limine memory map to allocate and free physical 4 KiB page frames.

This is the first real resource manager in the kernel. Until now, Limine has
prepared memory for us and our code has only used addresses that Limine gave us.
The physical memory manager, usually shortened to PMM, is where the kernel starts
tracking which physical pages are free and which are already in use.

Later systems depend on this:

- Page table code needs physical pages for new page tables.
- A heap allocator needs pages to back heap memory.
- Drivers may need page-aligned physical memory.

For the first version, keep the PMM deliberately simple and observable.

AI-native note: later plans may introduce memory planes as a policy layer above
physical and virtual memory. Do not build that policy into this allocator. The
PMM should remain a small, correct mechanism for tracking physical 4 KiB page
frames.

## Why This Comes Next

The next code needs a way to claim physical pages without guessing which RAM is
free. Page tables, kernel heap pages, stacks, and many driver buffers are backed
by physical frames. Until the PMM exists, any subsystem that needs a fresh page
would either reuse fixed addresses or corrupt memory that belongs to the
kernel, bootloader, firmware, framebuffer, or reserved hardware regions.

The PMM is needed for:

- allocating new page tables in the virtual memory plan;
- backing the future heap allocator;
- reserving memory that must never be handed out;
- tracking page-level accounting over serial logs;
- providing the mechanism that later memory-plane policy can build on.

## What We Will Build

- Page constants and alignment helpers.
- A bitmap that tracks one bit per physical page.
- PMM initialization from `BootInfo.memory_map`.
- `allocPage()` for one 4 KiB physical page.
- `freePage()` for returning one page.
- Basic accounting logs so we can see what the allocator thinks is available.

## Concepts To Understand First

### Physical Pages Versus Virtual Pages

A physical page is a real 4 KiB chunk of RAM, addressed by a physical address.
A virtual page is an address range in a page table. This plan only manages
physical pages. It does not create virtual mappings.

When `allocPage()` returns `0x12345000`, that is a physical address. You cannot
necessarily dereference it directly as a pointer. To access the memory, we use
the HHDM helper from Plan 02:

Example use inside `kernel/src/mem/pmm.zig`:

```zig
const virt = boot_info.physToHhdm(info, phys);
```

### Why 4 KiB

4 KiB is the normal base page size on x86_64 and aarch64. Larger pages exist,
but starting with 4 KiB pages keeps the allocator simple and works for page
tables.

### Why A Bitmap

A bitmap is compact:

```text
1 bit  = state of 1 physical page
1 byte = state of 8 physical pages
```

If the machine has 128 MiB of RAM:

```text
128 MiB / 4096 bytes per page = 32768 pages
32768 pages / 8 pages per byte = 4096 bitmap bytes
```

That is small enough for a bootstrap allocator and easy to debug.

## Function Map

```text
main.zig
  _start()
    const info = boot_info.load()
    boot_info.validate(&info)
    pmm.init(&info)

mem/page.zig
  size
  alignDown()
  alignUp()
  isAligned()

mem/pmm.zig
  init()
    findHighestUsable()
    findBitmapStorage()
    markUsableMemoryFree()
    reserveRange()
    reservePage()

  allocPage()
    isUsed()
    setUsed()

  freePage()
    isUsed()
    setUsed()
```

Here is what each function is for:

| Function | File | Purpose |
| --- | --- | --- |
| `page.alignDown` | `mem/page.zig` | Rounds an address down to the nearest 4 KiB boundary. |
| `page.alignUp` | `mem/page.zig` | Rounds an address up to the next 4 KiB boundary. |
| `page.isAligned` | `mem/page.zig` | Checks whether an address is already page-aligned. |
| `pmm.init` | `mem/pmm.zig` | Builds allocator state from the Limine memory map. |
| `findHighestUsable` | `mem/pmm.zig` | Finds the end of the highest usable memory range. |
| `bitmapBytes` | `mem/pmm.zig` | Computes how many bytes are needed to store one bit per page. |
| `findBitmapStorage` | `mem/pmm.zig` | Picks a usable memory range to hold the bitmap itself. |
| `markUsableMemoryFree` | `mem/pmm.zig` | Marks pages in Limine `.usable` ranges as free. |
| `reserveRange` | `mem/pmm.zig` | Marks a physical address range as used. |
| `reservePage` | `mem/pmm.zig` | Marks one physical page as used. |
| `isUsed` | `mem/pmm.zig` | Reads one page's bit from the bitmap. |
| `setUsed` | `mem/pmm.zig` | Updates one page's bit in the bitmap. |
| `allocPage` | `mem/pmm.zig` | Finds a free page, marks it used, and returns its physical address. |
| `freePage` | `mem/pmm.zig` | Validates and marks a physical page free again. |

## Math Notes

### Page Number From Address

Every physical page has an index:

Formula used in `kernel/src/mem/pmm.zig`:

```text
page_index = physical_address / 4096
```

And every page index has a physical base address:

Formula used in `kernel/src/mem/pmm.zig`:

```text
physical_address = page_index * 4096
```

This works because each page is exactly 4096 bytes.

### Alignment

Page-aligned addresses are multiples of 4096:

Mathematical definition used by `kernel/src/mem/page.zig`:

```text
address % 4096 == 0
```

Because 4096 is a power of two, we can use bit masks instead of division:

Formula implemented in `kernel/src/mem/page.zig`:

```zig
alignDown(value) = value & ~(4096 - 1)
isAligned(value) = (value & (4096 - 1)) == 0
```

`4096 - 1` is `0xfff`, which is the mask for the low 12 bits. Clearing those
low 12 bits rounds down to a page boundary.

`alignUp` adds `4095` first, then rounds down:

Formula implemented in `kernel/src/mem/page.zig`:

```zig
alignUp(value) = alignDown(value + 4095)
```

This moves any non-aligned value into the next page before clearing the low bits.

### Bitmap Byte And Bit

One bit represents one page:

Formula used by bitmap helpers in `kernel/src/mem/pmm.zig`:

```text
byte_index = page_index / 8
bit_index  = page_index % 8
mask       = 1 << bit_index
```

To check whether a page is used:

Expression used by `isUsed` in `kernel/src/mem/pmm.zig`:

```zig
(bitmap[byte_index] & mask) != 0
```

To mark it used:

Expression used by `setUsed` in `kernel/src/mem/pmm.zig`:

```zig
bitmap[byte_index] |= mask
```

To mark it free:

Expression used by `setUsed` in `kernel/src/mem/pmm.zig`:

```zig
bitmap[byte_index] &= ~mask
```

In this plan:

Bitmap convention used in `kernel/src/mem/pmm.zig`:

```text
1 = used
0 = free
```

That default is safer because we can initialize the whole bitmap to used and
only free ranges Limine explicitly marks as usable.

## Step 1: Define Page Constants

Create `kernel/src/mem/page.zig`.

Solution:

File: `kernel/src/mem/page.zig`

```zig
pub const size: usize = 4096;

pub fn alignDown(value: usize) usize {
    return value & ~(size - 1);
}

pub fn alignUp(value: usize) usize {
    return alignDown(value + size - 1);
}

pub fn isAligned(value: usize) bool {
    return (value & (size - 1)) == 0;
}
```

Why this file is separate:

- It has no Limine imports.
- It has no architecture-specific code.
- It can be unit-tested later with a normal Zig test target.
- Other memory code can share one definition of page size.

Checkpoint:

- `make kernel-x86_64` still builds.
- `make kernel-aarch64` still builds.

## Step 2: Define PMM State And Bitmap Helpers

Create `kernel/src/mem/pmm.zig`.

Start with a small global state object:

File: `kernel/src/mem/pmm.zig`

```zig
const page = @import("page.zig");

const State = struct {
    bitmap: []u8,
    total_pages: usize,
    free_pages: usize,
};

var state: ?State = null;
```

The state means:

- `bitmap`: the byte slice that stores page bits.
- `total_pages`: how many physical pages the bitmap can describe.
- `free_pages`: current count of free pages.
- `state == null`: PMM has not been initialized yet.

Add bitmap math helpers directly below the `State` and `state` definitions in
`kernel/src/mem/pmm.zig`. They are private PMM helpers because no other module
should need to know how the PMM bitmap is encoded.

File: `kernel/src/mem/pmm.zig`

```zig
fn bitmapBytes(total_pages: usize) usize {
    return (total_pages + 7) / 8;
}

fn bitmapLocation(page_index: usize) struct { byte: usize, mask: u8 } {
    const bit_index: u3 = @intCast(page_index % 8);
    return .{
        .byte = page_index / 8,
        .mask = @as(u8, 1) << bit_index,
    };
}

fn isUsed(bitmap: []const u8, page_index: usize) bool {
    const location = bitmapLocation(page_index);
    return (bitmap[location.byte] & location.mask) != 0;
}

fn setUsed(bitmap: []u8, page_index: usize, used: bool) void {
    const location = bitmapLocation(page_index);
    if (used) {
        bitmap[location.byte] |= location.mask;
    } else {
        bitmap[location.byte] &= ~location.mask;
    }
}
```

Why `bitmapBytes(total_pages)` adds 7:

If the page count is not divisible by 8, we still need one more byte for the
remaining pages.

Examples for `bitmapBytes` in `kernel/src/mem/pmm.zig`:

```text
1 page  -> 1 byte
8 pages -> 1 byte
9 pages -> 2 bytes
```

`(total_pages + 7) / 8` is integer division rounded up.

Checkpoint:

- The design can represent all pages up to the highest usable physical address.
- The bitmap convention is clear: `1` means used, `0` means free.

## Step 3: Initialize From `BootInfo`

`pmm.init` should receive the kernel-owned boot context:

File: `kernel/src/mem/pmm.zig`

```zig
const boot_info = @import("../boot/info.zig");

pub fn init(info: *const boot_info.BootInfo) void {
    // ...
}
```

Initialization has five jobs:

1. Find the highest usable physical address.
2. Compute how many pages exist up to that address.
3. Find a usable memory range large enough to store the bitmap.
4. Mark every page used by default.
5. Mark usable memory free, then reserve the bitmap and page zero.

Implementation:

File: `kernel/src/mem/pmm.zig`

```zig
pub fn init(info: *const boot_info.BootInfo) void {
    const highest = findHighestUsable(info.memory_map);
    const total_pages = page.alignUp(highest) / page.size;
    const bytes = bitmapBytes(total_pages);

    const bitmap_phys =
        findBitmapStorage(info.memory_map, bytes) orelse
        panic("no pmm bitmap storage");

    const bitmap_virt = boot_info.physToHhdm(info, bitmap_phys);
    const bitmap: []u8 = @as([*]u8, @ptrFromInt(bitmap_virt))[0..bytes];

    @memset(bitmap, 0xff);

    state = .{
        .bitmap = bitmap,
        .total_pages = total_pages,
        .free_pages = 0,
    };

    markUsableMemoryFree(info.memory_map);
    reserveRange(bitmap_phys, page.alignUp(bytes));
    reservePage(0);
}
```

Why `page.alignUp(highest) / page.size`:

- `highest` is an address, not a count.
- Rounding up makes sure a partial final page is represented.
- Dividing by page size converts bytes into page count.

Why the bitmap is accessed through HHDM:

- `bitmap_phys` is a physical address.
- Zig pointers are virtual addresses.
- Plan 02 gave us `boot_info.physToHhdm(info, bitmap_phys)`.
- That returns a virtual address mapped to the same physical memory.

Helper implementations:

File: `kernel/src/mem/pmm.zig`

```zig
fn findHighestUsable(memory_map: *limine.MemoryMapResponse) usize {
    var highest: usize = 0;
    for (memory_map.entries()) |entry| {
        if (entry.kind != .usable) continue;
        const end: usize = @intCast(entry.base + entry.length);
        if (end > highest) highest = end;
    }
    return highest;
}

fn findBitmapStorage(memory_map: *limine.MemoryMapResponse, bytes: usize) ?usize {
    const needed = page.alignUp(bytes);
    for (memory_map.entries()) |entry| {
        if (entry.kind != .usable) continue;

        const base: usize = page.alignUp(@intCast(entry.base));
        const end: usize = @intCast(entry.base + entry.length);
        if (base + needed <= end) return base;
    }
    return null;
}
```

The first version can rely on Limine marking kernel, bootloader, and framebuffer
regions as non-usable. Still log the memory map carefully so we can confirm that
assumption in QEMU.

Checkpoint:

- PMM logs total pages, free pages, used pages, and bitmap size.
- No page outside a Limine `.usable` range is marked free.
- The bitmap's own pages are reserved after usable memory is marked free.

## Step 4: Mark And Reserve Ranges

Before allocation works, the PMM needs helpers that change bitmap state by page
or by physical range.

Solution:

File: `kernel/src/mem/pmm.zig`

```zig
fn markPageUsed(page_index: usize, used: bool) void {
    var s = &(state orelse panic("pmm not initialized"));
    const was_used = isUsed(s.bitmap, page_index);
    if (was_used == used) return;

    setUsed(s.bitmap, page_index, used);
    if (used) {
        s.free_pages -= 1;
    } else {
        s.free_pages += 1;
    }
}

fn markRange(phys: usize, length: usize, used: bool) void {
    const start = page.alignDown(phys);
    const end = page.alignUp(phys + length);

    var current = start;
    while (current < end) : (current += page.size) {
        markPageUsed(current / page.size, used);
    }
}

fn markUsableMemoryFree(memory_map: *limine.MemoryMapResponse) void {
    for (memory_map.entries()) |entry| {
        if (entry.kind != .usable) continue;
        markRange(@intCast(entry.base), @intCast(entry.length), false);
    }
}

fn reserveRange(phys: usize, length: usize) void {
    markRange(phys, length, true);
}

fn reservePage(phys: usize) void {
    reserveRange(phys, page.size);
}
```

Why `markRange` aligns both ends:

- The allocator tracks whole pages, not arbitrary byte ranges.
- If any byte in a page must be reserved, the whole page should be reserved.
- `alignDown(start)` includes the first touched page.
- `alignUp(end)` includes the last touched page.

Checkpoint:

- Free-page accounting changes only when a bit actually changes.
- Reserving the same page twice does not decrement `free_pages` twice.

## Step 5: Allocate One Page

Add:

File: `kernel/src/mem/pmm.zig`

```zig
pub fn allocPage() ?usize
```

It returns a physical address, not a pointer.

Solution:

File: `kernel/src/mem/pmm.zig`

```zig
pub fn allocPage() ?usize {
    var s = &(state orelse return null);

    var index: usize = 0;
    while (index < s.total_pages) : (index += 1) {
        if (!isUsed(s.bitmap, index)) {
            setUsed(s.bitmap, index, true);
            s.free_pages -= 1;
            return index * page.size;
        }
    }

    return null;
}
```

Why this math returns a physical address:

Formula used by `allocPage` in `kernel/src/mem/pmm.zig`:

```text
physical_address = page_index * 4096
```

This first allocator uses a linear scan. That is slow for large memory, but it
is easy to understand, easy to debug, and good enough for the next milestone.

Checkpoint:

- Allocated addresses are 4 KiB aligned.
- Repeated allocation returns distinct pages.
- Free-page count decreases by one per successful allocation.

## Step 6: Free One Page

Add:

File: `kernel/src/mem/pmm.zig`

```zig
pub fn freePage(phys: usize) void
```

Validate aggressively. Early allocator bugs are easier to fix when they panic
immediately.

Solution:

File: `kernel/src/mem/pmm.zig`

```zig
pub fn freePage(phys: usize) void {
    var s = &(state orelse panic("pmm not initialized"));

    if (!page.isAligned(phys)) {
        panic("freePage: unaligned address");
    }

    const index = phys / page.size;
    if (index >= s.total_pages) {
        panic("freePage: out of range");
    }

    if (!isUsed(s.bitmap, index)) {
        panic("freePage: double free");
    }

    setUsed(s.bitmap, index, false);
    s.free_pages += 1;
}
```

Why check alignment:

- The allocator only owns whole pages.
- Freeing `0x1234` would be ambiguous.
- The only valid free address is the base of a page, such as `0x1000`,
  `0x2000`, or `0x3000`.

Checkpoint:

- Freeing then allocating can return the same physical page again.
- Double-free panics.
- Freeing an unaligned address panics.

## Step 7: Add Multi-Page Allocation Only If Needed

Do not add complex contiguous allocation until a later subsystem actually needs
it.

Page tables only need single 4 KiB pages, so `allocPage()` is enough for the
next plan. If a later driver or DMA use case needs contiguous physical pages,
add:

File: `kernel/src/mem/pmm.zig`

```zig
pub fn allocPages(count: usize) ?usize
pub fn freePages(base: usize, count: usize) void
```

A simple first-fit version would scan for `count` consecutive zero bits, mark
them used, and return the first page's physical address.

Checkpoint:

- The single-page path remains simple.
- Fragmentation is acknowledged but not solved prematurely.

## Done When

- The kernel can initialize PMM state from `BootInfo`.
- The bitmap lives in usable memory and reserves its own pages.
- `allocPage()` returns distinct 4 KiB-aligned physical addresses.
- `freePage()` returns pages to the allocator and catches invalid frees.
- Physical memory accounting is visible over serial.
- `make kernel-x86_64` and `make kernel-aarch64` both build.
