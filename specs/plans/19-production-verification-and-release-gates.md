# Plan 19: Production Verification And Release Gates

## Status

In progress. `make check` covers core/memory host tests and both kernel
architecture builds. `make check-smoke` extends that gate with an x86_64 QEMU
boot smoke that waits for and validates the machine-readable boot report, plus
a panic smoke that validates serial panic output.

## Goal

Define the verification bar for calling Zernel production-ready.

## Why This Comes Next

Production readiness is not a feature. It is a set of repeatable proofs:
builds, tests, boot checks, negative security tests, diagnostics, and release
metadata that make regressions visible.

## Work Items

1. Add a single host test aggregator for pure Zig core logic.
2. Add QEMU boot smoke for x86_64.
3. Add serial-output golden checks for boot report and panic paths.
4. Add negative tests for capability denial paths.
5. Add fault-injection boot tests once page faults are stable.
6. Add reproducible build notes and artifact hashes.
7. Add release metadata in boot report: version, commit, build mode.
8. Add `make check` that runs host tests and kernel builds.
9. Add CI documentation for required host tools.
10. Add security claim table that names what is true and what remains out of
    scope.

## Progress

- Done: single host test aggregator at `kernel/src/tests.zig`.
- Done: host aggregator covers core capability, cell, provenance, route,
  scheduler, and memory tests.
- Done: `make check` runs host tests and both architecture builds.
- Done: `make check-smoke` runs x86_64 QEMU and validates `__ZERNEL_BOOT_REPORT__`.
- Done: boot report golden-field checks for version, architecture, object count,
  capability count, cell count, route count, and minimum provenance count.
- Done: boot report includes build mode and git commit metadata.
- Done: security claims document separates enforced, modeled, and unclaimed
  properties.
- Done: x86_64 panic-path serial smoke checks for `PANIC`, panic reason, and
  halt marker.
- Remaining: CPU exception/fault serial-output golden checks.

## Expected Files

```text
Makefile
scripts/boot-smoke-x86_64.sh
scripts/panic-smoke-x86_64.sh
kernel/src/core/tests.zig
specs/docs/production-readiness.md
specs/docs/security-claims.md
```

## Validation

```sh
make check
make check-smoke
make kernel-x86_64
make kernel-aarch64
```

## Done When

- A new contributor can run one command to verify the production gate.
- Security claims are explicit and test-backed.
- Release artifacts carry enough metadata to identify their source.
