# Plan 03: Physical Memory Manager

## Goal

Use the Limine memory map to allocate and free physical 4 KiB page frames.

This is the first real kernel resource manager. Keep it deliberately small so
that virtual memory and heap allocation have a reliable base later.

## What We Will Build

- Page frame constants and address helpers.
- A physical memory manager initialization pass.
- A simple page allocator.
- Basic accounting and debug logs.

## Concepts To Understand First

- Page frames versus virtual pages.
- 4 KiB alignment.
- Usable versus reserved memory map entries.
- Why the kernel must not allocate memory occupied by itself, the bootloader,
  modules, framebuffer, or firmware tables.

## Step 1: Define Page Constants

Add:

- `page_size = 4096`.
- `alignDown`.
- `alignUp`.
- `isPageAligned`.

Solution:

Create `kernel/src/mem/page.zig`:

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

For host-side tests, keep these helpers free of kernel-only imports. A later
`zig test` target can import this file directly.

Checkpoint:

- Add unit tests for these helpers if they can run in a normal Zig test target.
- Kernel build remains freestanding.

## Step 2: Choose The First Allocator Design

Use a bitmap allocator unless there is a reason to start even simpler.

Reasonable first design:

- One bit per physical page.
- Bit value means used/free.
- Bitmap itself lives in usable memory selected during initialization.

Solution:

Create `kernel/src/mem/pmm.zig` with a small state object:

```zig
const page = @import("page.zig");

const State = struct {
    bitmap: []u8,
    total_pages: usize,
    free_pages: usize,
};

var state: ?State = null;
```

Use `1` to mean used and `0` to mean free. That makes initialization safer:
before the memory map has been processed, every page is considered unavailable.

The bitmap size is:

```zig
fn bitmapBytes(total_pages: usize) usize {
    return (total_pages + 7) / 8;
}
```

Checkpoint:

- The design can represent all memory up to the highest usable physical address.
- The bitmap does not overlap memory that will later be handed out.

## Step 3: Initialize From Memory Map

Initialization should:

- Mark every page used by default.
- Mark pages in usable memory map ranges free.
- Mark page zero used.
- Mark the bitmap storage used.
- Mark known kernel and bootloader ranges used if needed.

Solution:

Initialization has three phases:

1. Find the highest usable physical address.
2. Pick a usable range large enough to hold the bitmap.
3. Mark free pages, then reserve the bitmap pages.

Sketch:

```zig
pub fn init(info: *const BootInfo) void {
    const highest = findHighestUsable(info.memory_map);
    const total_pages = page.alignUp(highest) / page.size;
    const bytes = bitmapBytes(total_pages);
    const bitmap_phys = findBitmapStorage(info.memory_map, bytes) orelse panic("no pmm bitmap storage");
    const bitmap_virt = info.physToHhdm(bitmap_phys);

    const bitmap: []u8 = @as([*]u8, @ptrFromInt(bitmap_virt))[0..bytes];
    @memset(bitmap, 0xff);

    state = .{ .bitmap = bitmap, .total_pages = total_pages, .free_pages = 0 };

    markUsableMemoryFree(info.memory_map);
    reserveRange(bitmap_phys, page.alignUp(bytes));
    reservePage(0);
}
```

The first version can rely on Limine marking kernel, bootloader, and framebuffer
regions as non-usable. Still log the map carefully so we can confirm that
assumption in QEMU.

Checkpoint:

- Logs print total pages, free pages, used pages, and bitmap size.
- No page outside usable memory is marked free.

## Step 4: Allocate One Page

Add:

- `allocPage() ?usize`.

Return a physical address.

Solution:

Use a linear scan first:

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

This is not fast, but it is easy to inspect and debug. Add a `next_hint` later
if allocation speed becomes annoying.

Checkpoint:

- Allocated addresses are 4 KiB aligned.
- Repeated allocation returns distinct pages.
- Free page count decreases.

## Step 5: Free One Page

Add:

- `freePage(phys: usize) void`.

Validate:

- Address is page aligned.
- Address is in range.
- Page was allocated.

Solution:

```zig
pub fn freePage(phys: usize) void {
    var s = &(state orelse panic("pmm not initialized"));

    if (!page.isAligned(phys)) panic("freePage: unaligned address");

    const index = phys / page.size;
    if (index >= s.total_pages) panic("freePage: out of range");
    if (!isUsed(s.bitmap, index)) panic("freePage: double free");

    setUsed(s.bitmap, index, false);
    s.free_pages += 1;
}
```

Panicking on allocator misuse is the right behavior this early. Silent memory
corruption will waste much more time than a loud halt.

Checkpoint:

- Freeing then allocating can return the same page again.
- Double free panics or is rejected loudly.

## Step 6: Add Multi-Page Allocation Only If Needed

Do not add complex contiguous allocation until a later subsystem actually needs
it.

If needed, add:

- `allocPages(count: usize) ?usize`.
- `freePages(base: usize, count: usize)`.

Solution:

Delay this unless page table work actually needs contiguous physical pages. Page
tables only need single 4 KiB pages, so `allocPage()` is enough for the next
plan.

If a contiguous allocator is needed, implement it as a simple first-fit scan:

```zig
pub fn allocPages(count: usize) ?usize {
    if (count == 0) return null;
    // Scan for `count` consecutive free bits, mark them used, return base.
}
```

Document that this is not a long-term physical allocator strategy. It is a
teaching allocator and a bootstrap allocator.

Checkpoint:

- The single-page path remains simple.
- Fragmentation behavior is understood, even if not solved yet.

## Done When

- The kernel can allocate and free physical 4 KiB pages.
- Physical memory accounting is visible over serial.
- The allocator never hands out reserved memory.
