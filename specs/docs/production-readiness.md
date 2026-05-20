# Production Readiness

## Current Gates

`make check` is the fast local gate. It runs the Zig host test aggregator and
builds both supported kernel targets.

```sh
make check
```

`make check-smoke` is the stronger boot gate. It runs `make check`, builds the
x86_64 ISO, boots it in QEMU, validates the machine-readable boot report, then
boots a dedicated panic-smoke ISO and validates panic serial output.

```sh
make check-smoke
```

Security claims are tracked separately in
[`security-claims.md`](security-claims.md). Claims in that document must stay
tied to a gate.

## What The Gates Prove Today

- Core capability, cell, provenance, route, policy, dispatcher, scheduler, and
  memory tests pass.
- Cell stack metadata is host-tested for owner binding, stack-size validation,
  guard-page reservations, release, and slot reuse.
- Virtual stack layouts are host-tested for low guard, mapped stack, high guard,
  and outside-region classification.
- Per-cell address-space metadata is host-tested for cell ownership, stack
  attachment, mapped-state tracking, and owner mismatch rejection.
- x86_64 has a build-checked stack mapper primitive that validates cell page
  ownership and verifies guard pages remain unmapped.
- The x86_64 and aarch64 kernel binaries build in `ReleaseSafe`.
- The x86_64 ISO boots far enough to emit `__ZERNEL_BOOT_REPORT__`.
- The boot report matches expected golden fields for architecture and initial
  core object counts.
- The boot report includes release attribution fields: build mode and git
  commit.
- The panic path emits serial markers for panic start, reason, and halted state.

## What They Do Not Prove Yet

- Hardware timer interrupts are not driving scheduler ticks.
- CPU exception and fault serial output does not have golden smoke coverage yet.
- There is no user/kernel privilege separation yet.
- Cell isolation is still structural; address spaces exist as kernel metadata
  but do not yet have separate root page tables.
- Stack guard pages have tested layout semantics and an x86_64 mapper primitive,
  but there is not yet a cell launch path that exercises stack mapping at
  runtime.
- Mapped stack unmapping is not implemented yet, so mapped stacks are pinned
  instead of being safely reusable.
- Security claims are not complete until each claim is tied to a test or boot
  check.
