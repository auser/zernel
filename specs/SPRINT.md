# Zernel Sprint

## Purpose

Track the active production-readiness push for Zernel as a proper AI-native,
security-focused kernel.

Plan 12 is the north-star roadmap. Plans 13-19 break that roadmap into
implementation-sized workstreams. Keep this file updated whenever a plan item
starts, lands, is blocked, or changes scope.

## Current Focus

Cell isolation, memory safety, and production gates.

The immediate goal is to turn cells into the kernel's accountable execution
unit: pages, stacks, mappings, routes, scheduler ticks, and provenance should
all attach to an explicit `CellId`, with one command proving host tests, both
architecture builds, boot smoke, and panic smoke.

## Workstreams

| ID | Plan | Status | Current Attachment |
|---|---|---|---|
| P12 | [AI-Native Security Roadmap](plans/12-ai-native-security-roadmap.md) | Active roadmap | North star |
| P13 | [Capability Hardening](plans/13-capability-hardening.md) | In progress | Delegation rules and provenance hooks |
| P14 | [Provenance And Audit Trail](plans/14-provenance-and-audit-trail.md) | In progress | Machine-readable provenance and capability events |
| P15 | [Memory Safety Foundation](plans/15-memory-safety-foundation.md) | In progress | PMM ownership and cell memory APIs |
| P16 | [Timers And Scheduler Skeleton](plans/16-timers-and-scheduler-skeleton.md) | In progress | Current cell and budget tick accounting |
| P17 | [Cell Isolation Boundary](plans/17-cell-isolation-boundary.md) | In progress | Cell-owned pages, mappings, and stack metadata |
| P18 | [Route Dispatcher And Policy Hooks](plans/18-route-dispatcher-and-policy-hooks.md) | In progress | Dispatcher and default policy |
| P19 | [Production Verification And Release Gates](plans/19-production-verification-and-release-gates.md) | In progress | `make check`, boot smoke, claims |

## Active Checklist

- [x] Add provenance registry skeleton.
- [x] Record boot-time object, capability, cell, and route events.
- [x] Require source-cell capability ownership for route creation.
- [x] Require route-kind rights for route creation.
- [x] Add boot report line for machine parsing.
- [x] Add capability revocation and stale-generation rejection.
- [x] Add capability delegation rules.
- [x] Add machine-readable provenance dump.
- [x] Record provenance for route accept/complete/fail.
- [x] Record attributable denial provenance.
- [x] Add PMM accounting tests.
- [x] Add explicit PMM reserve/free range APIs.
- [x] Add overflow-safe PMM range validation.
- [x] Add overflow-safe PMM initialization arithmetic.
- [x] Add bootstrap heap plan implementation.
- [x] Initialize PMM and bootstrap heap during early boot.
- [x] Add PMM page ownership metadata.
- [x] Tag heap and page-table pages in PMM ownership metadata.
- [x] Add owner-specific PMM free validation.
- [x] Add per-cell memory page accounting.
- [x] Add core cell page allocate/free APIs.
- [x] Add cell-aware page mapping ownership validation.
- [x] Add typed mapping permissions with W^X rejection.
- [x] Add cell stack registry with guard-page metadata.
- [x] Add tested virtual stack layout with mapped and guard regions.
- [x] Add x86_64 stack-page mapper primitive that verifies guard pages remain unmapped.
- [x] Add per-cell address-space registry for stack attachment state.
- [x] Add core stack mapping entry point through the architecture mapper.
- [x] Reject freeing mapped stacks until an unmap path exists.
- [x] Add core cell stack allocate/free APIs with rollback.
- [x] Record cell stack allocation/free provenance names.
- [x] Add scheduler skeleton and current-cell identity.
- [x] Add scheduler budget tick accounting tests.
- [x] Add architecture timer initialization facade.
- [x] Add monitor-driven scheduler tick path.
- [ ] Wire an architecture timer interrupt into scheduler ticks.
- [x] Add route dispatcher skeleton.
- [x] Add default route policy hook.
- [x] Add monitor-driven route dispatch path.
- [x] Add `make check` production gate.
- [x] Add x86_64 QEMU boot smoke gate.
- [x] Add boot report golden-field validation.
- [x] Add release metadata to boot report.
- [x] Add test-backed security claims document.
- [x] Add x86_64 panic serial-output smoke gate.

## Definition Of Done For This Sprint

- Capability checks cover target, ownership, rights, revocation, and delegation.
- Provenance covers success and denial paths for core operations.
- Host tests prove the main authorization failure cases.
- Both architecture kernel builds pass.
- Plans and this sprint tracker reflect the actual state.

## Verification Commands

```sh
zig test kernel/src/core/capability.zig
zig test kernel/src/core/cell.zig
zig test kernel/src/core/route.zig
zig test kernel/src/core/provenance.zig
cd kernel && zig test src/tests.zig
make kernel-x86_64
make kernel-aarch64
make check
make check-smoke
```

## Notes

- Keep model runtimes out of ring 0.
- Keep external integrations deferred until Zernel has real enforcement.
- Do not claim security properties until there is a corresponding test or boot
  check.
