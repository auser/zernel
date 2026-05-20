# Plan 04: Virtual Memory Baseline

## Goal

Understand and safely extend the virtual memory environment Limine gives us.

Do not rush into replacing all mappings. The first target is page table literacy:
inspect, map, unmap, and translate in a controlled way.

AI-native note: virtual memory is the mechanism that later memory planes will
use. Keep this plan focused on page table correctness and explicit mappings.
Policy concepts like ephemeral memory, model memory, shared object memory, or
agent memory should be modeled above this layer after the basics are reliable.

## Why This Comes Next

The next code needs page table literacy before the kernel can safely create new
address spaces, map device memory, protect kernel data, or debug page faults.
Limine gives us a working virtual memory environment, but treating it as magic
will make later bugs opaque. We need to inspect what exists before we extend it.

Virtual memory helpers are needed for:

- mapping physical pages allocated by the PMM;
- translating virtual addresses during debugging;
- creating controlled mappings for devices, stacks, and heap memory;
- making page fault diagnostics actionable;
- giving future memory planes a concrete mapping mechanism instead of a policy
  name with no backend.

## What We Will Build

- x86_64 page table type definitions, kept behind the architecture boundary.
- Helpers for page table index extraction.
- A way to read the active root page table.
- A mapper that can create simple 4 KiB mappings.
- Typed mapping permissions that reject writable executable kernel mappings.
- Debug routines that log translations and mapping flags.
- A minimal aarch64 paging module for shared helpers where the concepts match.

## How This Code Gets Used

This plan builds a paging toolbox in stages. Not every helper should be used by
the boot path immediately.

The safest first runtime use is read-only inspection:

```text
BootInfo -> HHDM offset -> active page tables -> translate(existing virtual address)
```

That means the first boot integration should call `translate` for an address the
kernel already uses, such as the framebuffer address or a known kernel symbol,
and log the physical address, flags, and page size. This proves the page-table
walker is reading the live mappings correctly without changing any mappings.

The write-side helpers come later:

- `mapPage` is needed when the kernel wants to create a new virtual mapping for
  heap pages, stacks, guard pages, device memory, or object memory.
- `ensureNextTable` exists because `mapPage` may need to allocate missing
  intermediate page tables.
- `unmapPage` and `findPte` are needed after the kernel creates mappings that it
  later wants to remove.

Do not start Plan 04 by remapping the kernel or replacing Limine's page tables.
First inspect. Then add one controlled mapping. Only much later should the
kernel own a full address-space strategy.

## Concepts To Understand First

- Virtual address layout on x86_64.
- What pages are.
- PML4, PDPT, PD, and PT levels.
- Page table entries and flags.
- HHDM as a way to access physical page tables through virtual addresses.
- Why modifying live page tables requires careful invalidation.

### What Pages Are

A page is a fixed-size block of memory that the CPU's memory-management unit can
map, protect, and translate as one unit. In this plan, a normal page is 4 KiB.

There are two related ideas:

- A physical page frame is a real 4 KiB chunk of RAM. The PMM from Plan 03
  allocates these.
- A virtual page is a 4 KiB range in the address space the kernel uses in code.
  Page tables decide which physical page frame, if any, backs that virtual page.

For example:

```text
virtual page 0xffffffff80001000 -> physical frame 0x0000000000101000
```

Kernel code uses the virtual address. The CPU walks the page tables to find the
physical address before it actually reads or writes RAM.

Pages are needed because the kernel does not want every virtual address to mean
"the same number in physical RAM." Page tables let the kernel:

- map RAM wherever it wants in the virtual address space;
- leave some virtual ranges unmapped so bad accesses fault;
- mark pages read-only, writable, user-accessible, or non-executable;
- map device memory such as framebuffers;
- eventually give different tasks or cells different address spaces.

The low 12 bits of an address are the offset inside a 4 KiB page. The higher
bits select which page is being addressed.

```text
address:      0xffffffff80001234
page base:    0xffffffff80001000
page offset:  0x234
```

### What HHDM Is For In This Plan

HHDM means higher-half direct map. Plan 02 stores Limine's HHDM offset in
`BootInfo`.

In this plan, HHDM is how the kernel turns physical addresses from page table
entries into virtual pointers it can inspect. CR3 contains the physical address
of the root page table. Page table entries contain physical addresses of the
next page table. The kernel cannot use those physical addresses directly as Zig
pointers, so it translates them through the HHDM:

```text
page_table_virtual = hhdm_offset + page_table_physical
```

This is why `tableFromPhys` receives a physical address and returns a pointer:

```zig
fn tableFromPhys(info: *const BootInfo, phys: usize) *Table {
    return @ptrFromInt(boot_info.physToHhdm(info, phys));
}
```

HHDM does not allocate page tables, change mappings, or validate whether a page
is free. It only gives the kernel access to physical memory that Limine already
direct-mapped.

### Architecture Boundary

This plan starts with x86_64 because the current next step is reading CR3 and
walking x86_64's four-level page tables. AArch64 has different translation
registers, descriptor formats, and address-size configuration, so x86_64 page
table code must not be imported from shared kernel modules.

Shared code should go through the architecture facade:

```zig
const arch = @import("arch.zig");
const paging = arch.paging;
```

The common subset should stay small at first:

- `page_size`
- `pageOffset`

x86_64-specific helpers such as `readCr3`, `pml4Index`, `pdptIndex`, and
`activeRootTablePhys` belong in `kernel/src/arch/x86_64/paging.zig`. AArch64 can
grow its own `kernel/src/arch/aarch64/paging.zig` helpers when we are ready to
inspect TTBR/TCR-based translation tables.

## Math Notes

### 4-Level Page Table Indexes

x86_64 4 KiB paging uses four table levels. Each table has 512 entries:

```text
512 = 2^9
```

That means each level consumes 9 bits of the virtual address:

```text
bits 47..39 = PML4 index
bits 38..30 = PDPT index
bits 29..21 = PD index
bits 20..12 = PT index
bits 11..0  = offset within 4 KiB page
```

The mask `0x1ff` keeps 9 bits:

```text
0x1ff = 511 = 0b1_1111_1111
```

So:

```text
pml4_index = (virt >> 39) & 0x1ff
pt_index   = (virt >> 12) & 0x1ff
offset     = virt & 0xfff
```

### Page Offset

A 4 KiB page has `4096 = 2^12` bytes, so the low 12 bits are the byte offset
within the page:

```text
offset = virt & 0xfff
```

### Page Table Entry Address Mask

Page table entries store flags in low bits and a page-aligned physical address
in the higher bits. Since page addresses are 4 KiB aligned, their low 12 bits
are zero and can be used for flags.

This mask keeps the address bits and removes the flag bits:

```text
address_mask = 0x000f_ffff_ffff_f000
```

### Huge Pages

If the huge-page bit is set at the PDPT level, the mapping is 1 GiB. If it is
set at the PD level, the mapping is 2 MiB. In those cases, the offset is larger
than 12 bits because the mapping covers more than one 4 KiB page.

## Step 1: Add Address Index Helpers

Create helpers that extract:

- PML4 index.
- PDPT index.
- PD index.
- PT index.
- Page offset.

Solution:

Create `kernel/src/arch/x86_64/paging.zig`:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
pub const page_size: usize = 4096;

pub fn pml4Index(virt: usize) usize {
    return (virt >> 39) & 0x1ff;
}

pub fn pdptIndex(virt: usize) usize {
    return (virt >> 30) & 0x1ff;
}

pub fn pdIndex(virt: usize) usize {
    return (virt >> 21) & 0x1ff;
}

pub fn ptIndex(virt: usize) usize {
    return (virt >> 12) & 0x1ff;
}

pub fn pageOffset(virt: usize) usize {
    return virt & 0xfff;
}
```

These helpers are pure bit arithmetic, so they are good candidates for host-side
unit tests.

Checkpoint:

- Unit-test these helpers if possible.
- Log index breakdown for known kernel and framebuffer addresses.

## Step 2: Read CR3 On x86_64

Add a helper that reads CR3 and returns the physical address of the root page
table.

Solution:

Add:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
pub fn readCr3() usize {
    return asm volatile ("mov %%cr3, %[value]"
        : [value] "=r" (-> usize),
    );
}

pub fn activeRootTablePhys() usize {
    return readCr3() & ~@as(usize, 0xfff);
}
```

The low 12 bits of CR3 contain flags or process-context information depending
on CPU features. Mask them off before treating CR3 as a physical page address.

Checkpoint:

- Serial log prints the CR3 physical address.
- The address is page aligned.

## Step 3: Access Page Tables Through HHDM

Use `physToHhdm` from the boot info plan to get a virtual pointer to page table
memory.

Solution:

Import the boot info module so this file can name `BootInfo` and use the HHDM
helper:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
const boot_info = @import("../../boot/info.zig");
const BootInfo = boot_info.BootInfo;
```

Represent page tables as arrays of 512 entries:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
const Entry = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    huge: bool,
    global: bool,
    ignored_0: u3,
    address: u40,
    ignored_1: u11,
    no_execute: bool,
};

const Table = [512]Entry;
```

Then convert physical to virtual through HHDM:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
fn tableFromPhys(info: *const BootInfo, phys: usize) *Table {
    return @ptrFromInt(boot_info.physToHhdm(info, phys));
}
```

Page-table entries store the physical address shifted down by 12 bits. Add a
helper that reconstructs the physical address and another helper that follows an
entry to the next table:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
fn entryPhys(entry: Entry) usize {
    return @as(usize, entry.address) << 12;
}

fn tableFromEntry(info: *const BootInfo, entry: Entry) *Table {
    return tableFromPhys(info, entryPhys(entry));
}
```

If Zig complains about packed bool layout or pointer alignment, switch to a raw
`u64` entry with flag constants. Raw `u64` entries are less pretty but often
simpler for early paging code.

Checkpoint:

- The kernel can inspect present entries without changing them.
- Logs do not dereference unmapped physical addresses directly.

## Step 4: Implement Translation Inspection

Add a function:

- `translate(info: *const BootInfo, virt: usize) ?MappingInfo`.

It should walk the page tables and report:

- Physical address.
- Present/writable/user/no-execute flags if available.
- Page size.

Solution:

Walk the four levels from CR3:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
pub const MappingInfo = struct {
    phys: usize,
    flags: u64,
    page_size: usize,
};

pub fn translate(info: *const BootInfo, virt: usize) ?MappingInfo {
    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pml4e = pml4[pml4Index(virt)];
    if (!isPresent(pml4e)) return null;

    const pdpt = tableFromEntry(info, pml4e);
    const pdpte = pdpt[pdptIndex(virt)];
    if (!isPresent(pdpte)) return null;
    if (isHuge(pdpte)) return huge1GiBMapping(pdpte, virt);

    const pd = tableFromEntry(info, pdpte);
    const pde = pd[pdIndex(virt)];
    if (!isPresent(pde)) return null;
    if (isHuge(pde)) return huge2MiBMapping(pde, virt);

    const pt = tableFromEntry(info, pde);
    const pte = pt[ptIndex(virt)];
    if (!isPresent(pte)) return null;

    return .{
        .phys = entryPhys(pte) + pageOffset(virt),
        .flags = rawEntry(pte),
        .page_size = 4096,
    };
}
```

Add the small entry helpers used by `translate`:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
fn isPresent(entry: Entry) bool {
    return entry.present;
}

fn isHuge(entry: Entry) bool {
    return entry.huge;
}

fn rawEntry(entry: Entry) u64 {
    return @bitCast(entry);
}
```

Add constants and helpers for huge mappings:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
const page_size_2mib: usize = 2 * 1024 * 1024;
const page_size_1gib: usize = 1024 * 1024 * 1024;

const address_mask: u64 = 0x000f_ffff_ffff_f000;

fn huge1GiBMapping(entry: Entry, virt: usize) MappingInfo {
    const base = entryPhys(entry);
    const offset = virt & (page_size_1gib - 1);

    return .{
        .phys = base + offset,
        .flags = rawEntry(entry),
        .page_size = page_size_1gib,
    };
}

fn huge2MiBMapping(entry: Entry, virt: usize) MappingInfo {
    const base = entryPhys(entry);
    const offset = virt & (page_size_2mib - 1);

    return .{
        .phys = base + offset,
        .flags = rawEntry(entry),
        .page_size = page_size_2mib,
    };
}
```

Checkpoint:

- Translating `_start` returns a plausible physical address.
- Translating the framebuffer address returns a plausible mapping or clearly
  explains why not.

## Step 4a: Wire A Read-Only Paging Smoke Check

At this point the paging code exists, but it is only infrastructure until the
boot path calls it. The first call should inspect an existing mapping and log the
result. Do not call `mapPage` yet.

Solution:

In shared startup code, guard the x86_64-specific check with `builtin.cpu.arch`
so aarch64 stays buildable:

File: `kernel/src/main.zig`

```zig
const builtin = @import("builtin");
```

Then after `boot_info.logAddressInfo(&info)`:

File: `kernel/src/main.zig`

```zig
if (builtin.cpu.arch == .x86_64) {
    const framebuffer_virt = @intFromPtr(info.framebuffer.address);
    if (arch.paging.translate(&info, framebuffer_virt)) |mapping| {
        klog.info("framebuffer mapping");
        klog.labelHex("  virtual", framebuffer_virt);
        klog.labelHex("  physical", mapping.phys);
        klog.labelHex("  flags", mapping.flags);
        klog.labelDec("  page size", mapping.page_size);
    } else {
        klog.warn("framebuffer mapping not found");
    }
}
```

Why this address:

- The framebuffer is already being used by `paint`.
- Limine provided it as a virtual pointer.
- `translate` lets us verify what physical mapping backs that pointer.

This smoke check should only read page tables. If it fails, keep the failure as
a warning while the page-table walker is young.

Checkpoint:

- x86_64 boot logs include framebuffer virtual and physical mapping details, or
  a clear warning.
- aarch64 still builds and boots without compiling x86_64-specific page-table
  walking into shared code.

## Step 5: Map A Single Page

Add a function that maps one virtual page to one physical page with flags.

It should:

- Allocate intermediate page tables from the physical memory manager.
- Zero new page tables.
- Set entry flags.
- Invalidate the page with `invlpg`.

Solution:

Implement this only after the PMM exists. This file needs the PMM and panic
helpers:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
const panic = @import("../../panic.zig").panic;
const pmm = @import("../../mem/pmm.zig");
```

Then add the mapper:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
pub fn mapPage(info: *const BootInfo, virt: usize, phys: usize, flags: u64) void {
    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pdpt = ensureNextTable(info, &pml4[pml4Index(virt)]);
    const pd = ensureNextTable(info, &pdpt[pdptIndex(virt)]);
    const pt = ensureNextTable(info, &pd[pdIndex(virt)]);

    pt[ptIndex(virt)] = makeEntryRaw(phys, flags | flag_present);
    invlpg(virt);
}
```

`ensureNextTable` should allocate one physical page, zero it through HHDM, and
install it in the parent entry if the parent entry is not present. It must not
try to descend through a huge mapping.

File: `kernel/src/arch/x86_64/paging.zig`

```zig
const flag_present: u64 = 1 << 0;
const flag_huge: u64 = 1 << 7;

fn ensureNextTable(info: *const BootInfo, entry: *Entry) *Table {
    if (isPresent(entry.*)) {
        if (isHuge(entry.*)) {
            panic("ensureNextTable: huge mapping blocks table walk");
        }
        return tableFromEntry(info, entry.*);
    }

    const table_phys = pmm.allocPage() orelse panic("ensureNextTable: out of pages");
    const table = tableFromPhys(info, table_phys);
    @memset(@as([*]u8, @ptrCast(table))[0..page_size], 0);

    entry.* = makeEntry(table_phys, .{
        .present = true,
        .writable = true,
    });

    return table;
}
```

Add helpers for constructing entries:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
const EntryFlags = struct {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    huge: bool = false,
    no_execute: bool = false,
};

fn entryFromRaw(raw: u64) Entry {
    return @bitCast(raw);
}

fn makeEntryRaw(phys: usize, flags: u64) Entry {
    if ((phys & (page_size - 1)) != 0) {
        panic("makeEntryRaw: unaligned physical address");
    }
    return entryFromRaw((phys & address_mask) | flags);
}

fn makeEntry(phys: usize, flags: EntryFlags) Entry {
    if ((phys & (page_size - 1)) != 0) {
        panic("makeEntry: unaligned physical address");
    }

    return .{
        .present = flags.present,
        .writable = flags.writable,
        .user = flags.user,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = flags.huge,
        .global = false,
        .ignored_0 = 0,
        .address = @intCast(phys >> 12),
        .ignored_1 = 0,
        .no_execute = flags.no_execute,
    };
}
```

Finally, add TLB invalidation for the virtual page:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
fn invlpg(virt: usize) void {
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (virt),
        : "memory"
    );
}
```

`invlpg` is needed because the CPU may have cached the old translation in its
TLB. After changing a live page-table entry, invalidate that virtual address so
future memory accesses use the new mapping.

Checkpoint:

- Mapping a test virtual address to an allocated physical page succeeds.
- Writing through the mapped virtual address changes the expected physical page.

## Step 6: Unmap A Single Page

Add:

- `unmapPage(virt: usize)`.

Solution:

`findPte` means "find page table entry." It walks the same page-table path as
`translate`, but instead of returning a translated physical address, it returns
a pointer to the final 4 KiB PTE so the caller can modify it.

It must not allocate missing tables. Missing entries mean the virtual address is
not currently mapped as a normal 4 KiB page.

Add the helper:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
fn findPte(info: *const BootInfo, virt: usize) ?*Entry {
    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pml4e = pml4[pml4Index(virt)];
    if (!isPresent(pml4e)) return null;
    if (isHuge(pml4e)) return null;

    const pdpt = tableFromEntry(info, pml4e);
    const pdpte = pdpt[pdptIndex(virt)];
    if (!isPresent(pdpte)) return null;
    if (isHuge(pdpte)) return null;

    const pd = tableFromEntry(info, pdpte);
    const pde = pd[pdIndex(virt)];
    if (!isPresent(pde)) return null;
    if (isHuge(pde)) return null;

    const pt = tableFromEntry(info, pde);
    return &pt[ptIndex(virt)];
}
```

Then `unmapPage` can clear the final entry:

File: `kernel/src/arch/x86_64/paging.zig`

```zig
pub fn unmapPage(info: *const BootInfo, virt: usize) void {
    const mapping = findPte(info, virt) orelse panic("unmapPage: unmapped address");
    mapping.* = 0;
    invlpg(virt);
}
```

Notice that `findPte` checks the intermediate entries but not the final PTE. If
the intermediate tables exist, it returns the final slot. `unmapPage` then
clears that slot. If the final slot was already zero, clearing it again would
not be harmful, but panicking on unmapped addresses may be better later if we
want stricter misuse detection.

This helper deliberately returns `null` for huge mappings. Unmapping part of a
1 GiB or 2 MiB page requires splitting that huge mapping into smaller tables,
which is a later feature.

Do not free empty intermediate page tables yet. That optimization adds
bookkeeping complexity and is not needed for the first working mapper.

Checkpoint:

- Unmapping clears the entry.
- Accessing the unmapped page later should fault once exception handling exists.

## Done When

- The kernel can inspect current mappings.
- The boot path has one read-only x86_64 paging smoke check.
- The kernel can add at least one controlled mapping.
- Page table code uses the physical memory manager for new tables.
