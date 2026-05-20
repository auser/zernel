# Plan 18: Route Dispatcher And Policy Hooks

## Status

In progress. Pending route discovery, a default policy hook, and a dispatcher
that accepts the next pending route are implemented in host-tested code.

## Goal

Make routes the central work-request boundary, with policy hooks before
execution.

## Why This Comes Next

Direct cross-subsystem calls do not leave enough authority or provenance
context. Routes should become the point where the kernel asks: who requested
this, which capability authorizes it, what budget applies, and which executor is
allowed to handle it?

## Work Items

1. Add pending route queue semantics.
2. Add route executor registry metadata.
3. Add `accept`, `complete`, and `fail` APIs with provenance.
4. Add policy hook interface that can return accept, deny, or defer.
5. Add budget checks before route acceptance.
6. Add route result/error code fields.
7. Add denial provenance for policy rejects.
8. Add monitor commands for pending and completed routes.
9. Define first executor stubs for inspect and validate routes.

## Expected Files

```text
kernel/src/core/route.zig
kernel/src/core/dispatcher.zig
kernel/src/core/policy.zig
kernel/src/core/system.zig
kernel/src/interaction/monitor.zig
```

## Validation

```sh
zig test kernel/src/core/route.zig
make kernel-x86_64
```

## Done When

- Route status transitions are only performed through checked APIs.
- Policy can deny a route before execution.
- Route denial and completion are provenance-recorded.
- Executors cannot run without an accepted route.

## Progress

- Done: pending route lookup.
- Done: default policy hook with accept and defer decisions.
- Done: dispatcher accepts the next pending route through checked transitions.
- Done: monitor `dispatch` command exercises the dispatcher path.
- Done: dispatcher and policy host tests are included in `make check`.
- Remaining: policy denial tests backed by denied provenance.
- Remaining: executor registry metadata.
- Remaining: route result/error fields.
