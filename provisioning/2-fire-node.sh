#!/usr/bin/env bash
# 2-fire-node.sh — DESTRUCTIVE: reimage a node into the SLES AutoYaST installer via kexec.
# ---------------------------------------------------------------------------
# The provisioning primitive: a node currently running Ubuntu + k3s stages its OWN replacement.
# A privileged pod is scheduled onto the target node and, via `nsenter` into the host, installs
# kexec-tools, fetches the SLES installer kernel+initrd over HTTP, and `kexec`s straight into an
# unattended AutoYaST install that wipes the disk and lays down RKE2-on-SLES.
#
# No PXE, no TFTP, no BMC/console, no SSH — it drives entirely through the existing k8s API. That is
# what makes it work on OptiPlex-class hardware with no management controller.
#
# Usage:  BOOT_SERVER=http://<boot-server-ip>:8080 ./2-fire-node.sh <node-name> <profile.xml>
#   - <profile.xml> must already exist under $BOOT_SERVER/profiles/ and have its registration code
#     injected (run inject-regcode.sh first).
# ---------------------------------------------------------------------------
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

NODE="${1:?usage: 2-fire-node.sh <node-name> <profile.xml>}"
PROFILE="${2:?usage: 2-fire-node.sh <node-name> <profile.xml>}"
# The HTTP host serving the unpacked SLES tree (/sles) and the AutoYaST profiles (/profiles).
# See stage-boot-server.sh. NOT one of the nodes being wiped.
BS="${BOOT_SERVER:?set BOOT_SERVER, e.g. http://10.0.0.10:8080}"

PROV="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$PROV/$PROFILE" ] && grep -q '@@REG_CODE@@' "$PROV/$PROFILE"; then
  echo "ABORT: registration code not injected in $PROFILE — run ./inject-regcode.sh first"; exit 1
fi

# The script that runs ON the target host (via nsenter into PID 1): fetch the installer, kexec into it.
INNER="$(cat <<INNER
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y kexec-tools >/dev/null
curl -sf ${BS}/sles/boot/x86_64/loader/linux  -o /run/sles-linux
curl -sf ${BS}/sles/boot/x86_64/loader/initrd -o /run/sles-initrd
kexec -l /run/sles-linux --initrd=/run/sles-initrd \
  --command-line="install=${BS}/sles/ autoyast=${BS}/profiles/${PROFILE} ifcfg=en*=dhcp console=tty0"
sync
systemctl kexec &
INNER
)"
B64="$(printf '%s' "$INNER" | base64 -w0)"

# A privileged, host-namespaced pod pinned to the node, running the inner script.
OV="$(printf '{"spec":{"nodeName":"%s","hostPID":true,"hostNetwork":true,"tolerations":[{"operator":"Exists"}],"containers":[{"name":"f","image":"ubuntu:24.04","stdin":true,"securityContext":{"privileged":true},"command":["nsenter","--target","1","--mount","--uts","--ipc","--net","--pid","--","bash","-c","echo %s | base64 -d | bash"]}]}}' "$NODE" "$B64")"

echo ">>> FIRING $NODE with $PROFILE — it will kexec into the SLES installer and wipe itself."
timeout 120 kubectl run "fire-${NODE}" --image=ubuntu:24.04 --restart=Never --overrides="$OV" -i --rm 2>&1 \
  | grep -vE '^If you|will be recorded' | head
