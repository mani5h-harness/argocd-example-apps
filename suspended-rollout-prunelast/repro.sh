#!/usr/bin/env bash
# Reproduce: a Suspended Argo Rollout deadlocks a sync when PruneLast=true
# synthesises a second wave.
#
# Requires: kubectl, argocd CLI (logged in), an Argo Rollouts controller in the
# cluster, and this repo reachable from Argo CD.
#
# What it does:
#   A. points the app at step1 so the stale ConfigMap becomes live
#   B. points the app at step2 so the ConfigMap becomes a prune task
#   C. syncs, and watches the operation sit at Running / Suspended
#   D. runs the same thing without PruneLast as a control
set -euo pipefail

APP_REPRO="${APP_REPRO:-suspended-rollout-prunelast-repro}"
APP_CONTROL="${APP_CONTROL:-suspended-rollout-control}"
NS_REPRO="${NS_REPRO:-suspended-repro}"
WATCH_SECS="${WATCH_SECS:-180}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}
require kubectl
require argocd

say "0. preflight: Argo Rollouts CRD must be installed"
if ! kubectl get crd rollouts.argoproj.io >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Rollout CRD not found. Install the controller first, e.g.:
  kubectl create namespace argo-rollouts
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
EOF
  exit 1
fi

say "1. create both Applications"
kubectl apply -f "$HERE/argocd/application-repro.yaml"
kubectl apply -f "$HERE/argocd/application-control.yaml"

say "2. point repro app at step1 so the stale ConfigMap becomes live"
argocd app set "$APP_REPRO" --path suspended-rollout-prunelast/step1-with-configmap
argocd app sync "$APP_REPRO" --timeout 300
argocd app wait "$APP_REPRO" --health --timeout 300

echo "-- ConfigMap should now exist in the cluster:"
kubectl -n "$NS_REPRO" get configmap stale-config-abc123

say "3. arm the prune task: switch to step2 (ConfigMap gone from git, image changed)"
argocd app set "$APP_REPRO" --path suspended-rollout-prunelast/step2-configmap-removed

echo "-- expect: ConfigMap OutOfSync with requiresPruning, i.e. a prune task exists"
argocd app diff "$APP_REPRO" || true

say "4. sync the repro app (this is the deadlock; do NOT wait for it to finish)"
# --async so the CLI returns immediately; the operation itself will never complete.
argocd app sync "$APP_REPRO" --async || true

say "5. watch the stalled operation for ${WATCH_SECS}s"
end=$(( $(date +%s) + WATCH_SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  phase=$(argocd app get "$APP_REPRO" -o json | python3 -c \
    'import json,sys; d=json.load(sys.stdin); os=d["status"].get("operationState",{}); \
print("%s | %s | health=%s" % (os.get("phase","-"), os.get("message","-"), d["status"].get("health",{}).get("status","-")))')
  printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$phase"
  sleep 10
done

cat <<'EOF'

EXPECTED above: phase stays "Running" with message
  waiting for healthy state of argoproj.io/Rollout/suspended-repro
and health "Suspended", indefinitely. It never becomes Succeeded or Failed.

Confirm the synthesised wave — the prune task is in a later wave than the Rollout,
even though no sync-wave annotation exists anywhere:
EOF
echo '  kubectl -n argocd logs deploy/argocd-application-controller | grep -i "Tasks \["'
echo "  argocd app get $APP_REPRO -o json | jq '.status.operationState.syncResult.resources'"
echo "  # the ConfigMap should read: PruneSkipped / \"ignored (no prune)\""

say "6. control: same app WITHOUT PruneLast=true"
argocd app set "$APP_CONTROL" --path suspended-rollout-prunelast/step2-configmap-removed
argocd app sync "$APP_CONTROL" --timeout 120 || true
argocd app get "$APP_CONTROL" | sed -n '1,25p'

cat <<'EOF'

EXPECTED for the control: operation reaches Succeeded with
  "successfully synced (all tasks run)"
within seconds, even though its Rollout is ALSO Suspended.

That contrast is the whole finding: the paused Rollout alone is harmless.
PruneLast=true is what turns it into an unrecoverable sync.

Cleanup:
  argocd app delete suspended-rollout-prunelast-repro --cascade
  argocd app delete suspended-rollout-control --cascade
  argocd app delete suspended-rollout-hook-variant --cascade
EOF
