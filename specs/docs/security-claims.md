# Security Claims

This document separates enforced claims from modeled or future claims. A claim is
only marked enforced when it is backed by a host test, build gate, or boot smoke
check.

## Enforced Today

| Claim | Evidence | Gate |
|---|---|---|
| Capabilities can only target existing objects. | `core.capability` invalid-target tests. | `make check` |
| Revoked capabilities are rejected as active authority. | Capability revocation and stale-generation tests. | `make check` |
| Delegation requires an active source capability with `delegate`. | Capability and cell delegation denial tests. | `make check` |
| Delegation cannot escalate beyond source rights. | Capability delegation rights-containment tests. | `make check` |
| Cells only own capabilities at the recorded active generation. | Cell stale-generation ownership tests. | `make check` |
| Route creation requires a valid source cell, active capability, object target match, source ownership, and route-kind rights. | Route invalid reference, ownership, rights, and revoked-capability tests. | `make check` |
| Core provenance records are monotonically sequenced and use stable operation/result names. | Provenance sequence and name tests. | `make check` |
| PMM public range APIs reject uninitialized, unaligned, empty, out-of-range, overflow, and double-free cases. | PMM validation tests. | `make check` |
| PMM pages carry owner metadata and owner-specific frees reject mismatched owners. | PMM owner class and owner-mismatch tests. | `make check` |
| Cells account memory pages charged and released through the cell registry. | Cell memory accounting tests. | `make check` |
| Cell page mapping validation rejects pages not owned by the requesting cell and rejects writable executable mappings. | `mem.mapping` cell ownership and W^X tests. | `make check` |
| Cell stack metadata is bound to a concrete cell, validates stack size, tracks guard-page reservations, and can release/reuse stack slots. | Stack registry owner, size, guard metadata, and release/reuse tests. | `make check` |
| Address-space metadata creates one address space per cell, attaches stack layouts to the owning cell, and rejects stack owner mismatch. | `core.address_space` creation, attach, and owner-mismatch tests. | `make check` |
| Mapped stack metadata cannot be detached or freed until an unmap path exists. | Address-space mapped-detach rejection tests plus core build gate. | `make check-smoke` |
| Virtual stack layouts distinguish low guard, mapped stack pages, high guard, and outside addresses, and reject guard-page mappings. | `mem.virtual` stack layout tests. | `make check` |
| Kernel mapping permissions reject writable executable mappings at the typed API boundary. | `mem.mapping` W^X test. | `make check` |
| Bootstrap heap allocation has explicit failure behavior. | Heap alignment, page rollover, and failure tests. | `make check` |
| Scheduler state can name a current cell and charge ticks to the running cell. | Scheduler current-cell and tick-accounting tests. | `make check` |
| x86_64 boot emits a machine-readable boot report with release metadata and expected core counts. | QEMU smoke validates `__ZERNEL_BOOT_REPORT__`. | `make check-smoke` |
| The panic path emits serial diagnostics before halting. | Panic-smoke QEMU test validates panic start, reason, and halt markers. | `make check-smoke` |

## Modeled But Not Fully Enforced

| Area | Current State | Missing Enforcement |
|---|---|---|
| Cell isolation | Cells have IDs, lifecycle state, capabilities, scheduler identity, memory page accounting, cell-aware mapping validation, stack metadata, tested virtual stack layouts, and per-cell address-space attachment state. | Separate root page tables, runtime cell launch, enforced mapping boundaries, fault containment, and lower-privilege execution. |
| Route policy | Dispatcher and default policy accept/defer pending routes. | Policy denial tests, denial provenance for policy rejects, executor authorization, and budget enforcement. |
| W^X | Typed mapping permissions reject write+execute requests. | Auditing existing bootloader/kernel mappings and enforcing W^X across all live mappings. |
| Provenance | Core events are recorded in a fixed-size registry and can be dumped as JSON lines. | Drop accounting, capacity reporting, boot-smoke validation of provenance JSON, and tamper-resistant storage. |
| Scheduler | Current cell and software tick accounting exist. | Hardware timer interrupts, preemption, run queues, and time-budget enforcement. |
| Memory ownership | PMM accounting, owner tags, owner-specific free validation, bootstrap heap, core cell page APIs, cell stack allocation/free APIs, address-space stack attachment state, and an x86_64 stack-page mapper primitive exist. | VM-backed heap, stack unmapping, runtime cell launch, and current-cell page fault attribution. |

## Not Claimed

- No claim of complete kernel/user isolation.
- No claim that untrusted AI/model code can execute safely inside the kernel.
- No claim that cells are strong security sandboxes yet.
- No claim that all kernel memory is W^X at runtime.
- No claim of SMP safety.
- No claim of side-channel resistance.
- No claim of production-grade panic/fault recovery.
- No claim that CPU exception and page-fault paths are fully installed or
  smoke-tested yet.

## AI-Native Security Position

Zernel should treat AI work as route-driven, capability-checked, provenance-
recorded work. Model runtimes should stay outside ring 0. The kernel should
provide object identity, authority checks, isolation, routing, and audit trails;
it should not embed model inference as privileged kernel logic.
