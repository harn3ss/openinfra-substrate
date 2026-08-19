#!/usr/bin/env bash
# stage-boot-server.sh — serve the SLES installer tree + AutoYaST profiles over HTTP.
# ---------------------------------------------------------------------------
# Run this on a host on the same subnet that stays up during provisioning and is NOT one of the nodes
# being wiped. It unpacks the SLES Full ISO and serves it (plus your profiles) so 2-fire-node.sh can
# kexec the installer straight off HTTP.
#
# Usage: sudo ./stage-boot-server.sh /path/to/SLE-15-SP7-Full-x86_64-GM-Media1.iso [port]
# Then:  export BOOT_SERVER=http://<this-host-ip>:<port>
# ---------------------------------------------------------------------------
set -euo pipefail
ISO="${1:?usage: stage-boot-server.sh <sles-full-iso> [port]}"
PORT="${2:-8080}"
ROOT="${WWW_ROOT:-/srv/sles-boot}"
PROFILES_SRC="$(cd "$(dirname "$0")/../autoyast" && pwd)"

echo ">> [1/3] Unpacking the SLES tree to $ROOT/sles"
mkdir -p "$ROOT/sles" "$ROOT/profiles"
mnt="$(mktemp -d)"
mount -o loop,ro "$ISO" "$mnt"
cp -a "$mnt/." "$ROOT/sles/"
umount "$mnt"; rmdir "$mnt"

echo ">> [2/3] Publishing AutoYaST profiles to $ROOT/profiles"
# Copy the RENDERED profiles (autoinst-cn*.xml, produced by inject-regcode.sh) — NOT the templates.
cp -f "$PROFILES_SRC"/autoinst-cn*.xml "$ROOT/profiles/" 2>/dev/null || \
  echo "   (no rendered profiles yet — run inject-regcode.sh, then copy them into $ROOT/profiles/)"

echo ">> [3/3] Serving $ROOT on :$PORT (quick + dirty; use nginx for something durable)"
cd "$ROOT"
echo "   export BOOT_SERVER=http://$(hostname -I | awk '{print $1}'):$PORT"
exec python3 -m http.server "$PORT"
