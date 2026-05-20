# Zernel

Zernel is an experimental Zig kernel built around small, explicit kernel
primitives rather than a Unix compatibility layer. The early implementation
focuses on the foundations needed for a freestanding kernel: Limine boot,
serial logging, framebuffer output, physical and virtual memory setup, basic
interrupt and timer hooks, and an interactive monitor.

The longer-term direction is an AI-native kernel model based on typed objects,
capabilities, execution cells, routing, provenance, policy checks, and budgeted
execution. Those ideas are introduced as narrow kernel mechanisms first, while
the lower-level memory, interrupt, console, and allocator work stays the
priority.

## Status

Current targets:

- `x86_64` freestanding kernel with Limine boot support.
- `aarch64` freestanding kernel build and ISO support.
- QEMU boot paths for both targets.
- Host-side Zig tests for pure kernel logic.
- x86_64 smoke tests for boot-report and panic paths.

This is not a production operating system. It is a research and learning kernel
with intentionally small milestones documented under `specs/plans`.

## Requirements

- Zig 0.16.0 or newer.
- `make`.
- `git`.
- `xorriso` for ISO creation.
- QEMU:
  - `qemu-system-x86_64` for x86_64.
  - `qemu-system-aarch64` for aarch64.
- `jq` for the x86_64 boot smoke test.
- aarch64 QEMU firmware at `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`
  when using the provided aarch64 run/debug targets.

The Makefile clones and builds Limine into `boot/limine` on demand.

## Build

Build the default x86_64 ISO:

```sh
make
```

Build kernel binaries without creating ISOs:

```sh
make kernel-x86_64
make kernel-aarch64
make kernel-all
```

Build bootable ISOs:

```sh
make iso-x86_64
make iso-aarch64
make iso-all
```

The main outputs are:

- `kernel/zig-out/bin/kernel-x86_64`
- `kernel/zig-out/bin/kernel-aarch64`
- `zernel-x86_64.iso`
- `zernel-aarch64.iso`

## Run

Run the default x86_64 ISO in QEMU:

```sh
make run
```

Run a specific architecture:

```sh
make run-x86_64
make run-aarch64
```

Use the debug targets for serial output on stdio and no automatic shutdown:

```sh
make debug-x86_64
make debug-aarch64
```

## Test

Run host-side Zig tests and build both kernel targets:

```sh
make check
```

Run x86_64 smoke tests in QEMU:

```sh
make smoke-x86_64
make smoke-panic-x86_64
```

Run the full local check suite:

```sh
make check-smoke
```

The smoke scripts wait for serial markers from QEMU. Timeout values can be
overridden with:

- `ZERNEL_BOOT_SMOKE_TIMEOUT_SECONDS`
- `ZERNEL_PANIC_SMOKE_TIMEOUT_SECONDS`

## Clean

Remove generated ISOs and Zig outputs:

```sh
make clean
```

Also remove the cloned Limine checkout:

```sh
make distclean
```

## Repository Layout

```text
boot/
  limine.conf              Limine boot configuration.
kernel/
  build.zig                Kernel build script.
  linker-*.ld              Architecture-specific linker scripts.
  src/
    arch/                  Architecture-specific code.
    boot/                  Limine boot information handling.
    core/                  Objects, capabilities, cells, routes, policy.
    fb/                    Framebuffer console support.
    interaction/           Serial monitor and input handling.
    mem/                   Page, PMM, mapping, and heap code.
    utils/                 Logging and panic support.
scripts/
  *-smoke-x86_64.sh        QEMU smoke-test scripts.
specs/
  plans/                   Step-by-step implementation plans.
  docs/                    Project notes and readiness/security docs.
```

## Planning Documents

The milestone plan starts at `specs/plans/README.md`. The main sequence covers
architecture setup, serial logging, Limine boot metadata, memory management,
interrupts, framebuffer output, the serial monitor, and the first AI-native
kernel primitives.

For design vocabulary, see:

- `specs/plans/ai-native-kernel-primitives.md`
- `specs/docs/security-claims.md`
- `specs/docs/production-readiness.md`

## Notes

- `make` builds with `-Doptimize=ReleaseSafe` by default.
- The Makefile passes the current git commit into the kernel as boot metadata.
- x86_64 disables hardware floating-point features and uses `soft_float`.
- The Limine config disables KASLR for the current development workflow.
