#!/usr/bin/env bash
# Push the bundled runtime to a Termux device over SSH and install it.
# Set TERMUX_SSH to an SSH alias or user@host that can reach Termux.
# Install parameters (CONTROL_URL, AUTH_KEY_FILE, NODE_HOSTNAME, TAILNET_CIDR,
# ...) are forwarded as environment variables; see README.md.
# The auth key itself is never transferred: create ~/.tailscale/authkey on the
# phone first (or pass AUTH_KEY to install-termux.sh directly on the phone).
set -euo pipefail
cd "$(dirname "$0")"

TERMUX_SSH="${TERMUX_SSH:-termux}"
DEST="/data/data/com.termux/files/home/tailnet-deploy"
files=(bin vendor termux patches install-termux.sh README.md)

for f in "${files[@]}"; do
  [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

echo "==> syncing to $TERMUX_SSH:$DEST"
ssh "$TERMUX_SSH" "rm -rf '$DEST' && mkdir -p '$DEST'"
tar -cf - "${files[@]}" | ssh "$TERMUX_SSH" "tar -xf - -C '$DEST'"

envcmd=""
for v in CONTROL_URL AUTH_KEY_FILE NODE_HOSTNAME TAILNET_CIDR TAILNET_SSH_GLOB \
         SSH_PORT SOCKS5_LISTEN HTTP_PROXY_LISTEN ACCEPT_DNS ACCEPT_ROUTES \
         SVCNAME TAILNET_RESTART; do
  val="${!v:-}"
  if [ -n "$val" ]; then
    envcmd+="$v=$(printf '%q' "$val") "
  fi
done

echo "==> installing on phone"
ssh "$TERMUX_SSH" "${envcmd}bash '$DEST/install-termux.sh'"
echo "==> done"
