# Plan 04: Virtual Memory Baseline

## Goal

Understand and safely extend the virtual memory environment Limine gives us.

Do not rush into replacing all mappings. The first target is page table literacy:
inspect, map, unmap, and translate in a controlled way.

## What We Will Build

- x86_64 page table type definitions.
- Helpers for page table index extraction.
- A way to read the active root page table.
- A mapper that can create simple 4 KiB mappings.
- Debug routines that log translations and mapping flags.

## Concepts To Understand First

- Virtual address layout on x86_64.
- PML4, PDPT, PD, and PT levels.
- Page table entries and flags.
- HHDM as a way to access physical page tables through virtual addresses.
- Why modifying live page tables requires careful invalidation.

## Step 1: Add Address Index Helpers

Create helpers that extract:

- PML4 index.
- PDPT index.
- PD index.
- PT index.
- Page offset.

Solution:

Create `kernel/src/arch/x86_64/paging.zig`:

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

Represent page tables as arrays of 512 entries:

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

```zig
fn tableFromPhys(info: *const BootInfo, phys: usize) *Table {
    return @ptrFromInt(info.physToHhdm(phys));
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

- `translate(virt: usize) ?MappingInfo`.

It should walk the page tables and report:

- Physical address.
- Present/writable/user/no-execute flags if available.
- Page size.

Solution:

Walk the four levels from CR3:

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

Start with raw `u64` helpers if that makes the code shorter:

```zig
const present: u64 = 1 << 0;
const huge: u64 = 1 << 7;
const address_mask: u64 = 0x000f_ffff_ffff_f000;
```

Checkpoint:

- Translating `_start` returns a plausible physical address.
- Translating the framebuffer address returns a plausible mapping or clearly
  explains why not.

## Step 5: Map A Single Page

Add a function that maps one virtual page to one physical page with flags.

It should:

- Allocate intermediate page tables from the physical memory manager.
- Zero new page tables.
- Set entry flags.
- Invalidate the page with `invlpg`.

Solution:

Implement this only after the PMM exists:

```zig
pub fn mapPage(info: *const BootInfo, virt: usize, phys: usize, flags: u64) void {
    const pml4 = tableFromPhys(info, activeRootTablePhys());
    const pdpt = ensureNextTable(info, &pml4[pml4Index(virt)]);
    const pd = ensureNextTable(info, &pdpt[pdptIndex(virt)]);
    const pt = ensureNextTable(info, &pd[pdIndex(virt)]);

    pt[ptIndex(virt)] = makeEntry(phys, flags | present);
    invlpg(virt);
}
```

`ensureNextTable` should allocate one physical page, zero it through HHDM, and
install it in the parent entry if the parent entry is not present.

```zig
fn invlpg(virt: usize) void {
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (virt),
        : "memory"
    );
}
```

Checkpoint:

- Mapping a test virtual address to an allocated physical page succeeds.
- Writing through the mapped virtual address changes the expected physical page.

## Step 6: Unmap A Single Page

Add:

- `unmapPage(virt: usize)`.

Solution:

Walk to the final PTE and clear it:

```zig
pub fn unmapPage(info: *const BootInfo, virt: usize) void {
    const mapping = findPte(info, virt) orelse panic("unmapPage: unmapped address");
    mapping.* = 0;
    invlpg(virt);
}
```

Do not free empty intermediate page tables yet. That optimization adds
bookkeeping complexity and is not needed for the first working mapper.

Checkpoint:

- Unmapping clears the entry.
- Accessing the unmapped page later should fault once exception handling exists.

## Done When

- The kernel can inspect current mappings.
- The kernel can add at least one controlled mapping.
- Page table code uses the physical memory manager for new tables.
