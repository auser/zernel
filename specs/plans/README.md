# Zernel Step-By-Step Plans

These plans continue from the current milestone: the kernel builds, boots
through Limine, runs in QEMU, and writes a framebuffer gradient.

Walk through them in order. Each plan is intentionally scoped so we can learn
one layer of the workflow before building on it.

Each step includes an inline `Solution` section. Treat those as tutorial
solutions and implementation sketches, not final polished kernel APIs. When a
solution depends on exact Limine or Zig package names, prefer the compiler and
the current dependency version over the spelling in the prose.

## Order

1. [Architecture Facade](00-architecture-facade.md)
2. [Early Serial Logging](01-early-serial-logging.md)
3. [Limine Boot Info](02-limine-boot-info.md)
4. [Physical Memory Manager](03-physical-memory-manager.md)
5. [Virtual Memory Baseline](04-virtual-memory-baseline.md)
6. [Exceptions And Interrupts](05-exceptions-and-interrupts.md)
7. [Framebuffer Text Console](06-framebuffer-text-console.md)

## Why This Order

The architecture facade comes first because the kernel already targets more than
one CPU architecture, and shared code needs one stable way to ask for
architecture-specific behavior. Serial logging comes next because every later
subsystem needs diagnostics. Limine boot info follows because it tells the
kernel what machine state it inherited. Physical memory comes before virtual
memory because new page tables need physical pages. Exceptions come after basic
memory work so faults can be debugged clearly. The framebuffer console comes
after serial because it is more complex and should not be the only debugging
path.

## Working Style

For each plan:

1. Read the goal and concepts first.
2. Implement one step.
3. Boot in QEMU.
4. Confirm the checkpoint.
5. Commit or note the working state before moving on.

## Blog Draft Notes

The plans are structured so each file can become one blog post:

- Start with the goal and the reason for the order.
- Explain the concepts before showing code.
- Walk through each solution in sequence.
- End each section with the checkpoint output or QEMU behavior.
- Keep the final code in the repository as the source of truth when the prose
  and implementation drift.
