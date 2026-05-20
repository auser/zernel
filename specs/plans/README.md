# Zernel Step-By-Step Plans

These plans continue from the current milestone: the kernel builds, boots
through Limine, runs in QEMU, and writes a framebuffer gradient.

Walk through them in order. Each plan is intentionally scoped so we can learn
one layer of the workflow before building on it.

## North Star: AI-Native Kernel Primitives

Zernel is not trying to become a Unix clone first and an AI runtime later. The
early milestones still build normal kernel foundations, but the long-term design
favors typed objects, explicit capabilities, execution cells, memory policy,
routing, provenance, and budgeted agent execution.

Near-term rule: do not add model/runtime complexity before the kernel has
correct memory, interrupts, console, and allocator foundations. The first
AI-native milestones should introduce vocabulary and narrow kernel mechanisms,
not networked model calls or large in-kernel runtimes.

See [AI-Native Kernel Primitives](ai-native-kernel-primitives.md) for the shared
vocabulary these plans are growing toward.

Each step includes concrete implementation details: file paths, public APIs,
boot wiring, monitor commands when relevant, and verification commands. Treat
the code snippets as the intended implementation shape, not abstract sketches.
When a solution depends on exact Limine or Zig package names, prefer the
compiler and the current dependency version over stale prose.

## Implementation Standard

Every plan must include enough implementation detail to build the feature
without inventing the architecture while coding. At minimum, each plan should
name:

- exact files to create or edit;
- public functions, structs, enums, and errors;
- boot-time wiring through `main.zig` or another owning module;
- monitor commands or debug dumps when the feature is meant to be observable;
- validation and failure behavior;
- host-side tests for pure logic where practical;
- the build or test command that proves the step works.

Avoid placeholder-only plans. If a plan introduces a registry, route, cell,
input path, or other kernel mechanism, it must also say what initializes it,
what consumes it, and how to inspect it.

## Order

1. [Architecture Facade](00-architecture-facade.md)
2. [Early Serial Logging](01-early-serial-logging.md)
3. [Limine Boot Info](02-limine-boot-info.md)
4. [Physical Memory Manager](03-physical-memory-manager.md)
5. [Virtual Memory Baseline](04-virtual-memory-baseline.md)
6. [Exceptions And Interrupts](05-exceptions-and-interrupts.md)
7. [Framebuffer Text Console](06-framebuffer-text-console.md)
8. [Serial Kernel Monitor](07-serial-kernel-monitor.md)
9. [Kernel Object And Capability Skeleton](08-kernel-object-and-capability-skeleton.md)
10. [Execution Cell Skeleton](09-execution-cell-skeleton.md)
11. [Routing Plane Skeleton](10-routing-plane-skeleton.md)
12. [Input Roadmap](11-input-roadmap.md)
13. [AI-Native Security Roadmap](12-ai-native-security-roadmap.md)
14. [Capability Hardening](13-capability-hardening.md)
15. [Provenance And Audit Trail](14-provenance-and-audit-trail.md)
16. [Memory Safety Foundation](15-memory-safety-foundation.md)
17. [Timers And Scheduler Skeleton](16-timers-and-scheduler-skeleton.md)
18. [Cell Isolation Boundary](17-cell-isolation-boundary.md)
19. [Route Dispatcher And Policy Hooks](18-route-dispatcher-and-policy-hooks.md)
20. [Production Verification And Release Gates](19-production-verification-and-release-gates.md)

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

The serial kernel monitor comes before the AI-native skeletons because it gives
us the first interactive inspection path without needing keyboard interrupts.
That means object, capability, cell, and route registries can be queried through
commands instead of only dumped during boot.

The first AI-native plans come after console output because their main value is
observability: typed objects, capabilities, cells, and routes should be easy to
dump and inspect while they are still small. They also come before storage,
networking, and model execution so those later systems can be built around the
right primitives instead of retrofitted.

The input roadmap captures the path after the first serial monitor: stabilize
polled serial input first, split interaction helpers only when the code earns
the structure, and wait for interrupt/device foundations before keyboard input.

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
