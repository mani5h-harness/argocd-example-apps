# Repro: a Suspended Rollout deadlocks a sync when `PruneLast=true` invents a second wave

This directory reproduces a sync operation that stays `Running` **forever** with:

```
waiting for healthy state of argoproj.io/Rollout/suspended-repro
```

and, when driven by a Harness GitOps Sync step:

```
1 application(s) not yet synced.
Error: waiting for healthy state of argoproj.io/Rollout/suspended-repro
Sync Status: Running
Health: Suspended
```

**There are no `argocd.argoproj.io/sync-wave` annotations anywhere in this repro.** That is
the point. The commonly held belief is that health-gated waiting only happens with sync
waves; in fact `PruneLast=true` plus a single prunable resource is enough to synthesise
the extra wave, and a `PostSync` hook is enough on its own too.

## The mechanism

```
PruneLast=true  +  at least one prunable resource
        ↓  prune tasks get waveOverride = lastSyncWave + 1
sync_context.go:1128-1145
        ↓  wave() != lastWave()
sync_tasks.go:274-276           multiStep() == true
        ↓  multiStep && task.running()  ->  hold the wave, return early
sync_context.go:577-598
        ↓  Rollout is canary-paused, so health = "Suspended"
resource_customizations/argoproj.io/Rollout/health.lua:40-52, 89-98
        ↓  health switch handles ONLY Healthy and Degraded; Suspended falls through
sync_context.go:556-571         <-- root defect: task stays Running forever
        ↓
sync_context.go:426-476         setRunningPhase -> "waiting for healthy state of ..."
        ↓  Harness requires a TERMINAL phase (Succeeded|Failed|Error)
SyncRunnable.java:1201-1230
        ↓  never terminal -> poll loop runs to its deadline
SyncRunnable.java:983-1129
        ↓
SyncRunnable.java:1133-1144     "N application(s) not yet synced"
        ↓  Running -> syncStillRunningForApps -> Status.FAILED
SyncStep.java:147-155
```

Two details worth internalising:

1. **The `Error:` line is Argo's message, not Harness's.** It comes from
   `status.operationState.message` via `ApplicationResource.getSyncMessage()`
   (`930-ng-core-clients/.../gitops/models/ApplicationResource.java:444-449`).
2. **`autoPromoteRolloutBehavior: RESUME` cannot rescue this.** `applyAutoPromoteBehavior`
   is only called from `SyncRunnable.java:1077` and `:1085`, both inside the
   `isApplicationSyncComplete(...)` branch and both gated on `isSyncSuccess(...)`. The
   sync never reaches a terminal successful phase, so the one mechanism designed to
   resume a paused Rollout is unreachable in exactly the deadlock it targets.

## Layout

| Path | Role |
|---|---|
| `step1-with-configmap/` | Rollout (`:blue`) + Service + a `Prune=false` ConfigMap. Sync this **first** to make the ConfigMap live. |
| `step2-configmap-removed/` | Same Rollout with `:yellow` (triggers the canary) + Service. ConfigMap absent → it becomes a **prune task**. |
| `step3-hook-no-prunelast/` | Variant C: no PruneLast, no prunes — a `PostSync` Job satisfies `multiStep()` via the *phase* half. |
| `argocd/application-repro.yaml` | **Broken case.** `PruneLast=true`. |
| `argocd/application-control.yaml` | **Control.** Identical minus `PruneLast=true`. Syncs fine despite the same Suspended Rollout. |
| `argocd/application-hook-variant.yaml` | Variant C app. |
| `harness/sync-step-pipeline.yaml` | Harness pipeline that surfaces the step-level "not yet synced" message. |
| `repro.sh` | Driver for the whole sequence. |

## Prerequisites

- A cluster with the **Argo Rollouts controller** installed:
  ```
  kubectl create namespace argo-rollouts
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  ```
- Argo CD (or a Harness GitOps agent) with this repo reachable.
- `kubectl` and a logged-in `argocd` CLI.

## Quick run

```bash
./repro.sh
```

## Manual run

```bash
# 1. create the app and establish the live ConfigMap
kubectl apply -f argocd/application-repro.yaml
argocd app set suspended-rollout-prunelast-repro \
  --path suspended-rollout-prunelast/step1-with-configmap
argocd app sync suspended-rollout-prunelast-repro
argocd app wait suspended-rollout-prunelast-repro --health

kubectl -n suspended-repro get configmap stale-config-abc123   # must exist

# 2. arm the prune task and change the image so the canary starts
argocd app set suspended-rollout-prunelast-repro \
  --path suspended-rollout-prunelast/step2-configmap-removed

# 3. sync — this operation will never terminate
argocd app sync suspended-rollout-prunelast-repro --async

# 4. observe
watch -n5 "argocd app get suspended-rollout-prunelast-repro -o json | \
  jq -r '.status.operationState | .phase + \" | \" + .message'"
```

### Expected

```
Running | waiting for healthy state of argoproj.io/Rollout/suspended-repro
```

held indefinitely, with app health `Suspended` and the Rollout stuck at the `pause: {}`
step. It becomes neither `Succeeded` nor `Failed`.

Confirm the prune is both *later* and *useless*:

```bash
argocd app get suspended-rollout-prunelast-repro -o json \
  | jq '.status.operationState.syncResult.resources[] | select(.kind=="ConfigMap")'
# => "status": "PruneSkipped", "message": "ignored (no prune)"
```

That ConfigMap gates an entire wave while doing nothing — the same irony as the
production case that prompted this repro (5 ConfigMaps, all `PruneSkipped`).

Optionally inspect the synthesised wave directly:

```bash
kubectl -n argocd logs deploy/argocd-application-controller | grep -i 'Tasks \['
# each syncTask prints as "<phase>/<wave> resource <group>/<kind>/<ns>/<name> ..."
# (sync_task.go:36-43) — the Rollout is wave 0, the ConfigMap prune is wave 1
```

## The control — this is what makes it a proof

```bash
kubectl apply -f argocd/application-control.yaml
argocd app set suspended-rollout-control \
  --path suspended-rollout-prunelast/step2-configmap-removed
argocd app sync suspended-rollout-control
```

Its Rollout goes `Suspended` too, but the operation reaches:

```
Succeeded | successfully synced (all tasks run)
```

within seconds, via the single-wave completion path at `sync_context.go:704-716`.

**A paused Rollout on its own is harmless. `PruneLast=true` is what makes it fatal.**

## Variant C — no PruneLast, no prunes, still stalls

```bash
kubectl apply -f argocd/application-hook-variant.yaml
argocd app sync suspended-rollout-hook-variant --async
```

Same stall. Here `multiStep()` is true because `phase() != lastPhase()` (Sync vs PostSync),
not because of waves. Three independent routes reach the same gate:

| Route | `multiStep()` clause | Sync-wave annotation needed? |
|---|---|---|
| Real sync waves | `wave() != lastWave()` | yes |
| `PruneLast=true` + a prune task | `wave() != lastWave()` | **no** |
| Any PreSync/PostSync/SyncFail hook | `phase() != lastPhase()` | **no** |

## Recovering / clearing the deadlock

```bash
# promote past the pause -> Rollout leaves Suspended -> the sync completes
kubectl argo rollouts promote suspended-repro -n suspended-repro

# or terminate the stuck operation
argocd app terminate-op suspended-rollout-prunelast-repro
```

## Fixes, ranked

1. **Remove the stale prunable resource.** No prune task → no synthetic wave. In the
   production case those resources were `PruneSkipped` anyway, so they cost a wave and
   returned nothing.
2. **Drop `PruneLast=true`.** Single wave, so the engine completes right after apply.
   Trade-off: prune ordering is lost.
3. ~~Set `waitTillHealthy: false` on the Sync step.~~ **This does not help.** See below.

### `waitTillHealthy` is a red herring

The customer pipeline had `waitTillHealthy: false` and still hit this. `waitTillHealthy`
is read in exactly one place — `SyncRunnable.java:1035` — inside the
`isApplicationSyncComplete(...)` branch and additionally gated on `isSyncSuccess(...)`:

```java
// SyncRunnable.java:1020, 1035
if (isApplicationSyncComplete(currentApplicationState, syncStatus, syncStartTime, ...)) {
  ...
  if (isSyncSuccess(syncStatus) && waitTillHealthy) {   // <-- only reader
```

The deadlock occurs because `isApplicationSyncComplete` is **false** (Argo reports
`Running`, which is not a terminal phase per `:1226-1230`). Execution never reaches line
1035, so the flag's value is irrelevant. The waiting is imposed by the **Argo engine**
holding the wave, not by Harness waiting on health.

Corollary: `failOnTimeout` must also be false, because `SyncRunnable.java:196-198`
throws `IllegalStateException("failOnTimeout set but waitTillHealthy not set")`.

The step fails via the "still running" branch (`SyncStep.java:147-155`), never the
`failOnTimeout` branch (`:137-145`) — so no combination of these two flags avoids it.
Only fixes 1 and 2 above actually work.

## Cleanup

```bash
argocd app delete suspended-rollout-prunelast-repro --cascade
argocd app delete suspended-rollout-control --cascade
argocd app delete suspended-rollout-hook-variant --cascade
```

## Source references

| File | Lines | Relevance |
|---|---|---|
| `gitops-engine/pkg/sync/sync_context.go` | 350-372 | `getOperationPhase` — the **hook** path *does* map `Suspended` → Running |
| | 426-476 | `setRunningPhase`; line 438 sets `reason = "healthy state of"` |
| | 556-571 | resource health switch — **no `Suspended` case** (root defect) |
| | 577-598 | `multiStep`-gated early return |
| | 704-716 | single-wave / last-wave success path |
| | 1128-1145 | `PruneLast` rewrites prune tasks to `lastWave + 1` |
| | 1486 | `PruneSkipped` / `"ignored (no prune)"` |
| `gitops-engine/pkg/sync/sync_tasks.go` | 274-276 | `multiStep()` — wave **or** phase |
| `gitops-engine/pkg/sync/sync_task.go` | 94-104 | `pending` / `running` / `completed` |
| `resource_customizations/argoproj.io/Rollout/health.lua` | 40-52, 89-98 | paused Rollout → `Suspended` |
| `harness-core` `SyncRunnable.java` | 983-1129, 1133-1144, 1201-1230 | poll loop, report, terminal-phase gate |
| | 1077, 1085, 1827-1906 | auto-promote call sites (gated) and handler |
| `harness-core` `SyncStep.java` | 147-155 | `Running` → `Status.FAILED` |
| `harness-core` `ApplicationResource.java` | 444-449 | `getSyncMessage()` |
