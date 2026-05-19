# Plan 05: Exceptions And Interrupts

## Goal

Install basic CPU tables so faults become readable kernel diagnostics instead of
silent hangs or QEMU resets.

This comes after serial logging because exception handlers need somewhere
reliable to report what happened.

## Why This Comes Next

The next code needs controlled failure. Once the kernel starts touching page
tables, allocating memory, and eventually accepting timer or device interrupts,
faults are expected. Without a GDT, IDT, and exception path, a small mistake can
turn into a triple fault, QEMU reset, or silent hang with no address or vector to
debug.

Exceptions and interrupts are needed for:

- readable page fault diagnostics while VM code is developed;
- catching invalid memory access, bad instructions, and protection faults;
- enabling timer interrupts for scheduling later;
- supporting keyboard, mouse, storage, and network interrupts later;
- giving future execution cells a path toward preemption and failure reporting.

## What We Will Build

- A minimal GDT.
- A minimal IDT.
- Exception stubs.
- A common exception handler that logs vector, error code, and instruction
  pointer.
- A page fault handler that logs the faulting address.

## Concepts To Understand First

- GDT role in long mode.
- IDT entries and interrupt gates.
- Exception vectors.
- Interrupt stack frames.
- Error-code versus no-error-code exceptions.
- CR2 for page fault address.

## Math Notes

### Descriptor Pointer Size

The CPU expects `lgdt` and `lidt` operands to contain:

```text
limit: 16 bits = 2 bytes
base:  64 bits = 8 bytes
total:          10 bytes
```

That is why the descriptor pointer size check expects 10 bytes.

The `limit` is the table size minus one:

```text
limit = byte_size_of_table - 1
```

For an IDT with 256 entries and 16 bytes per entry:

```text
size  = 256 * 16 = 4096 bytes
limit = 4096 - 1 = 4095
```

### Segment Selectors

Each GDT entry is 8 bytes. A selector is the byte offset of the entry in the
GDT:

```text
null descriptor = index 0 -> selector 0x00
code descriptor = index 1 -> selector 1 * 8 = 0x08
data descriptor = index 2 -> selector 2 * 8 = 0x10
```

That is why the plan uses:

```text
kernel_code_selector = 0x08
kernel_data_selector = 0x10
```

### Splitting Handler Addresses

An IDT entry stores a 64-bit handler address in three chunks:

```text
offset_low  = bits 0..15
offset_mid  = bits 16..31
offset_high = bits 32..63
```

So the code uses truncation and shifts:

```text
offset_low  = truncate(addr)
offset_mid  = truncate(addr >> 16)
offset_high = truncate(addr >> 32)
```

### Exception Error Codes

Some CPU exceptions push an error code and some do not. To give Zig one uniform
frame shape, no-error-code stubs push a synthetic `0`. That way the common
handler can always read:

```text
vector
error_code
saved CPU frame
```

### Page Fault Address

For vector 14, the CPU stores the faulting virtual address in CR2. Reading CR2
does not decode the fault by itself; it only tells us which virtual address
caused the fault.

## Step 1: Add Descriptor Types

Define packed structures for:

- GDT entries.
- GDT pointer.
- IDT entries.
- IDT pointer.

Solution:

Create `kernel/src/arch/x86_64/descriptors.zig`.

For descriptor pointers:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
pub const DescriptorPointer = packed struct {
    limit: u16,
    base: u64,
};
```

For the IDT, use the x86_64 interrupt gate layout:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
pub const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    reserved_0: u5,
    gate_type: u4,
    zero: u1,
    dpl: u2,
    present: bool,
    offset_mid: u16,
    offset_high: u32,
    reserved_1: u32,
};
```

Add compile-time size checks:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
comptime {
    if (@sizeOf(IdtEntry) != 16) @compileError("bad IDT entry size");
    if (@sizeOf(DescriptorPointer) != 10) @compileError("bad descriptor pointer size");
}
```

Checkpoint:

- Struct sizes match CPU expectations.
- Compile-time assertions verify sizes where possible.

## Step 2: Load A Minimal GDT

Add:

- Null descriptor.
- Kernel code descriptor.
- Kernel data descriptor.

Then load it with `lgdt`.

Solution:

In long mode, segmentation is mostly disabled, but the CPU still expects valid
code and data selectors.

Start with static entries:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
const gdt = [_]u64{
    0x0000000000000000, // Null.
    0x00af9a000000ffff, // Kernel code.
    0x00af92000000ffff, // Kernel data.
};

pub const kernel_code_selector: u16 = 0x08;
pub const kernel_data_selector: u16 = 0x10;
```

Load it:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
pub fn loadGdt() void {
    const ptr = DescriptorPointer{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    asm volatile ("lgdt (%[ptr])"
        :
        : [ptr] "r" (&ptr),
        : "memory"
    );
}
```

A later refinement should reload segment registers and perform a far return or
far jump for CS. For the first pass, keep the change small and verify QEMU
behavior carefully.

Checkpoint:

- Kernel still reaches framebuffer paint after loading the GDT.
- Serial logs confirm GDT load.

## Step 3: Create IDT Entries

Initialize entries for CPU exceptions first.

Solution:

Create a 256-entry IDT:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
var idt: [256]IdtEntry = [_]IdtEntry{emptyEntry()} ** 256;
```

Add a helper:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
fn setGate(vector: u8, handler: *const fn () callconv(.naked) void) void {
    const addr = @intFromPtr(handler);
    idt[vector] = .{
        .offset_low = @truncate(addr),
        .selector = kernel_code_selector,
        .ist = 0,
        .reserved_0 = 0,
        .gate_type = 0xe,
        .zero = 0,
        .dpl = 0,
        .present = true,
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
        .reserved_1 = 0,
    };
}
```

Load it:

File: `kernel/src/arch/x86_64/descriptors.zig`

```zig
pub fn loadIdt() void {
    const ptr = DescriptorPointer{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&ptr),
        : "memory"
    );
}
```

Checkpoint:

- IDT table is loaded with `lidt`.
- Interrupts can remain disabled while exception handling is tested.

## Step 4: Add Exception Stubs

Add low-level assembly stubs that normalize the stack layout and call a Zig
handler.

Keep the first version simple:

- Save enough registers for useful diagnostics.
- Pass vector number.
- Pass error code.
- Pass instruction pointer and code segment from the CPU frame.

Solution:

Use one stub per exception vector at first. Some exceptions push an error code
and some do not. For exceptions without an error code, push a synthetic `0` so
the Zig handler sees one uniform frame.

Sketch for a no-error-code vector:

File: `kernel/src/arch/x86_64/interrupts.zig`

```zig
export fn isr_invalid_opcode() callconv(.naked) void {
    asm volatile (
        \\ pushq $0
        \\ pushq $6
        \\ jmp common_exception_stub
    );
}
```

Sketch for a vector with an error code, such as page fault:

File: `kernel/src/arch/x86_64/interrupts.zig`

```zig
export fn isr_page_fault() callconv(.naked) void {
    asm volatile (
        \\ pushq $14
        \\ jmp common_exception_stub
    );
}
```

The common stub should save registers, pass a pointer to a frame into Zig, call
`exceptionHandler`, restore registers, remove the vector/error-code values, and
`iretq`.

Keep this as a focused implementation task. Inline assembly syntax is the most
likely part to need iteration against the current Zig version.

Checkpoint:

- Trigger `ud2` intentionally.
- Serial output reports invalid opcode instead of silently hanging.

## Step 5: Add Page Fault Diagnostics

Read CR2 in the page fault handler and print:

- Faulting virtual address.
- Error code.
- Instruction pointer.

Solution:

Add:

File: `kernel/src/arch/x86_64/interrupts.zig`

```zig
fn readCr2() usize {
    return asm volatile ("mov %%cr2, %[value]"
        : [value] "=r" (-> usize),
    );
}
```

Then in the common handler:

File: `kernel/src/arch/x86_64/interrupts.zig`

```zig
pub fn exceptionHandler(frame: *const ExceptionFrame) noreturn {
    klog.writeLabelDec("exception vector", frame.vector);
    klog.writeLabelHex("error code", frame.error_code);
    klog.writeLabelHex("rip", frame.rip);

    if (frame.vector == 14) {
        klog.writeLabelHex("page fault address", readCr2());
    }

    panic("unhandled CPU exception");
}
```

Use `noreturn` until there is a specific exception we know how to recover from.

Checkpoint:

- Intentionally read an unmapped address.
- Serial output reports a page fault with the expected address.

## Step 6: Decide When To Enable External Interrupts

Do not enable hardware IRQs until the PIC/APIC story is clear.

For now:

- Exceptions work.
- CPU interrupts can remain disabled.
- Timer and keyboard IRQs are later work.

Solution:

Leave `_start` using `cli`/disabled interrupts for now. CPU exceptions still
arrive even when external interrupts are disabled.

Add a comment near IDT setup:

File: `kernel/src/arch/x86_64/interrupts.zig`

```zig
// External IRQs stay disabled until PIC/APIC initialization exists.
// This IDT is for CPU exceptions only.
```

The next interrupt-related plan should explicitly cover PIC masking,
local APIC setup, timer interrupts, and end-of-interrupt handling.

Checkpoint:

- The kernel has readable diagnostics for exceptions.
- There is no accidental interrupt storm from unconfigured hardware.

## Done When

- Invalid instructions and page faults produce serial diagnostics.
- The kernel no longer fails silently for basic CPU exceptions.
- External hardware interrupts are intentionally deferred.
