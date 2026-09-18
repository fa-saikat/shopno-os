# ADR-002: Boot Gate Scoped to `multi-user.target`, Not the Edition's Default Target

**Status:** Accepted
**Date:** 2026-09-18

## Context

`tests/smoke/test-iso-boots.sh`'s boot-marker service needed a way to signal "the system finished booting cleanly" over a QEMU serial console. The obvious primitive, `systemctl is-system-running --wait`, is scoped to the *entire* initial boot transaction — on GUI editions (`desktop`, `gaming`) that means waiting for `graphical.target`, which pulls in Xorg, LightDM, and the full XFCE session. Under QEMU software rendering that chain is slow and comparatively failure-prone for reasons unrelated to packaging or layer-composition regressions — the actual thing this gate exists to catch.

Two other primitives were tried and rejected before landing on the final design. `systemctl start --wait <target>` hangs indefinitely even on an already-active target, because `--wait` on `start` waits for the unit to reach an end-state, and persistent target units never deactivate on their own. Bare `systemctl is-system-running` (no `--wait`) still reported `starting` instead of `running` once ordering had already released the marker unit, because it's scoped to the whole transaction, not to any specific target — the same underlying mismatch as the `--wait` case, just without the hang.

## Decision

Gate on `multi-user.target` only, for every edition uniformly. `After=`/`WantedBy=multi-user.target` on the marker unit lets systemd's own ordering do the waiting; the unit's `ExecStart` then takes a plain, non-blocking snapshot scoped to exactly that point in boot: `systemctl is-active multi-user.target` combined with an empty `systemctl --failed` list.

## Consequences

- One marker unit works identically across `core`, `desktop`, and `gaming` — no per-edition branching needed.
- Desktop-session correctness (Xorg/LightDM/XFCE actually rendering) is not verified by this gate. A separate, later marker is planned for that, tracked as a metric before being promoted to a blocking gate — matching the project's own non-blocking-first pattern already adopted for `grype`.
- Accepted gap: since `*.target` files typically declare dependencies via `Wants=` rather than `Requires=`, a unit that fails a few seconds *after* this snapshot is taken won't be caught. Waiting longer to catch it is exactly what reintroduces the `graphical.target` coupling this decision exists to avoid.
