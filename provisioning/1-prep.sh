#!/usr/bin/env bash
# 1-prep.sh — non-destructive prep before reimaging: drain the target nodes and pause anything that
# would schedule work onto them mid-reimage. Safe to run anytime.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# The nodes about to be reimaged (space-separated). Override for your fleet.
NODES="${NODES:-chaos-node-1 chaos-node-2 chaos-node-3}"

echo "== pausing scheduled workloads (edit for your CI) so they don't fire at nodes mid-reimage =="
# Example: disable any nightly/continuous jobs that target these nodes.
# gh workflow disable continuous-chaos.yml 2>/dev/null || true
# gh workflow disable nightly-chaos.yml   2>/dev/null || true

echo "== cordon + drain: $NODES =="
for n in $NODES; do
  kubectl cordon "$n" || true
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s || true
done

echo "prep done. Nodes cordoned/drained. They stay cluster members until you fire (2-fire-node.sh)"
echo "and delete the stale Node objects."
