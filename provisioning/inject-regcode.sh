#!/usr/bin/env bash
# inject-regcode.sh — fill the SUSE eval registration code + email into the AutoYaST profiles.
# ---------------------------------------------------------------------------
# The profiles ship with @@REG_CODE@@ / @@REG_EMAIL@@ placeholders so the eval code NEVER lives in
# git. This reads them from a local .env (never committed — see .gitignore) and renders per-node
# copies. Run it on the host that holds your .env; the rendered autoinst-cn*.xml are also gitignored.
#
# .env must contain:
#   SUSE_REG_CODE=...
#   SUSE_REG_EMAIL=...
#
# Usage: ./inject-regcode.sh [path/to/.env]   (default: ./.env)
# ---------------------------------------------------------------------------
set -euo pipefail
ENV_FILE="${1:-./.env}"
AUTOYAST="$(cd "$(dirname "$0")/../autoyast" && pwd)"

code="$(grep -E '^SUSE_REG_CODE='  "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'')"
email="$(grep -E '^SUSE_REG_EMAIL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'')"
[ -n "$code" ]  || { echo "SUSE_REG_CODE not found in $ENV_FILE";  exit 1; }
[ -n "$email" ] || { echo "SUSE_REG_EMAIL not found in $ENV_FILE"; exit 1; }

# Render each node from a template into a gitignored autoinst-cn*.xml (carrying the injected code).
# Adjust the per-node loop (hostname, server line, token) to your topology.
src="$AUTOYAST/autoinst.template.xml"     # or autoinst-hardened.xml for the hardened build
for n in 1 2 3; do
  out="$AUTOYAST/autoinst-cn${n}.xml"
  sed -e "s|@@REG_CODE@@|$code|g" -e "s|@@REG_EMAIL@@|$email|g" "$src" > "$out"
done
echo "rendered $(ls "$AUTOYAST"/autoinst-cn*.xml | wc -l) profiles (gitignored)."
grep -L '@@REG_CODE@@' "$AUTOYAST"/autoinst-cn*.xml >/dev/null && echo "no reg-code placeholders remain — ready."
