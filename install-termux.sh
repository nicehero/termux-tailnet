#!/data/data/com.termux/files/usr/bin/bash
# Install a Tailscale-compatible userspace runtime into Termux.
# Run this ON THE PHONE from a copied project directory. Everything needed is
# bundled in this repository; no network access is required.
#
# Parameters are environment variables, see README.md:
#   CONTROL_URL, AUTH_KEY_FILE, AUTH_KEY, NODE_HOSTNAME, TAILNET_CIDR,
#   TAILNET_SSH_GLOB, SSH_PORT, SOCKS5_LISTEN, HTTP_PROXY_LISTEN,
#   ACCEPT_DNS, ACCEPT_ROUTES, SVCNAME, TAILNET_RESTART
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"
TSDIR="$HOME/tailscale"
STATE="$HOME/.tailscale"
SOCK="$PREFIX/tmp/tailscaled.sock"
SVDIR="$PREFIX/var/service"
CONFDIR="$HOME/.config/termux-tailnet"
LOGDIR="$HOME/.local/state/tailnet/log"

CONTROL_URL="${CONTROL_URL:-}"
AUTH_KEY="${AUTH_KEY:-}"
AUTH_KEY_FILE="${AUTH_KEY_FILE:-$STATE/authkey}"
NODE_HOSTNAME="${NODE_HOSTNAME:-termux}"
TAILNET_CIDR="${TAILNET_CIDR:-}"
TAILNET_SSH_GLOB="${TAILNET_SSH_GLOB:-}"
SSH_PORT="${SSH_PORT:-8022}"
SOCKS5_LISTEN="${SOCKS5_LISTEN:-127.0.0.1:1055}"
HTTP_PROXY_LISTEN="${HTTP_PROXY_LISTEN:-127.0.0.1:1056}"
ACCEPT_DNS="${ACCEPT_DNS:-false}"
ACCEPT_ROUTES="${ACCEPT_ROUTES:-false}"
TAILNET_RESTART="${TAILNET_RESTART:-0}"

say() { printf '==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }

for c in tar ssh sv svlogd pkill grep sed; do need "$c"; done

mkdir -p "$TSDIR" "$STATE" "$CONFDIR" "$LOGDIR"
chmod 700 "$STATE" "$CONFDIR"

# Reuse an existing supervised service if one already runs tailscaled-v2.
if [ -z "${SVCNAME:-}" ]; then
  for d in "$SVDIR"/*; do
    if [ -f "$d/run" ] && grep -q 'tailscaled-v2' "$d/run" 2>/dev/null; then
      SVCNAME="$(basename "$d")"
      break
    fi
  done
fi
SVCNAME="${SVCNAME:-tailnet}"
SVC="$SVDIR/$SVCNAME"
say "service name: $SVCNAME"

# 1. Official CLI + daemon. Extract to a staging dir and rename into place:
#    writing to a running executable returns ETXTBSY on Linux/Android.
STAGE="$TSDIR/.stage.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -xzf "$BASE/vendor/tailscale_1.104.2_arm64.tgz" -C "$STAGE" --strip-components=1
mv -f "$STAGE/tailscale" "$TSDIR/tailscale"
mv -f "$STAGE/tailscaled" "$TSDIR/tailscaled"
rm -rf "$STAGE"
chmod 700 "$TSDIR/tailscale" "$TSDIR/tailscaled"

# 2. Patched daemon. Same rename trick because it is usually running.
cp "$BASE/bin/tailscaled-v2" "$TSDIR/tailscaled-v2.new"
chmod 700 "$TSDIR/tailscaled-v2.new"
mv -f "$TSDIR/tailscaled-v2.new" "$TSDIR/tailscaled-v2"

# 3. Auth key. Prefer the existing file; AUTH_KEY writes it if supplied.
if [ -n "$AUTH_KEY" ]; then
  umask 077
  printf '%s' "$AUTH_KEY" > "$AUTH_KEY_FILE"
fi
if [ -s "$AUTH_KEY_FILE" ]; then
  chmod 600 "$AUTH_KEY_FILE"
else
  echo "WARN: no auth key at $AUTH_KEY_FILE; login will be skipped" >&2
fi

# 4. Runtime configuration (no secrets). The runit run script sources this.
ENV_FILE="$CONFDIR/env"
{
  printf 'SOCKS5_LISTEN=%q\n' "$SOCKS5_LISTEN"
  printf 'HTTP_PROXY_LISTEN=%q\n' "$HTTP_PROXY_LISTEN"
  printf 'CONTROL_URL=%q\n' "$CONTROL_URL"
  printf 'NODE_HOSTNAME=%q\n' "$NODE_HOSTNAME"
  printf 'TAILNET_CIDR=%q\n' "$TAILNET_CIDR"
  printf 'ACCEPT_DNS=%q\n' "$ACCEPT_DNS"
  printf 'ACCEPT_ROUTES=%q\n' "$ACCEPT_ROUTES"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 5. SSH ProxyCommand helper.
cp "$BASE/termux/ts-nc" "$HOME/ts-nc"
chmod 700 "$HOME/ts-nc"

# 6. SSH client config. Derive a Host glob from the CIDR when possible.
if [ -z "$TAILNET_SSH_GLOB" ] && [ -n "$TAILNET_CIDR" ]; then
  cidr="${TAILNET_CIDR%/*}"
  bits="${TAILNET_CIDR#*/}"
  IFS=. read -r o1 o2 o3 o4 <<< "$cidr"
  case "$bits" in
    8) [ -n "$o1" ] && TAILNET_SSH_GLOB="$o1.*.*.*" ;;
    16) [ -n "$o2" ] && TAILNET_SSH_GLOB="$o1.$o2.*.*" ;;
    24) [ -n "$o3" ] && TAILNET_SSH_GLOB="$o1.$o2.$o3.*" ;;
  esac
  if [ -z "$TAILNET_SSH_GLOB" ]; then
    echo "WARN: cannot derive SSH glob from TAILNET_CIDR=$TAILNET_CIDR; set TAILNET_SSH_GLOB" >&2
  fi
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"
if [ -n "$TAILNET_SSH_GLOB" ]; then
  if ! grep -q 'ProxyCommand .*[/]ts-nc %h %p' "$HOME/.ssh/config"; then
    {
      printf '\nHost %s\n' "$TAILNET_SSH_GLOB"
      printf '    ProxyCommand %s/ts-nc %%h %%p\n' "$HOME"
    } >> "$HOME/.ssh/config"
  fi
else
  echo "NOTE: no TAILNET_CIDR/TAILNET_SSH_GLOB; skipping ~/.ssh/config" >&2
fi

# 7. runit service.
mkdir -p "$SVC/log"
cp "$BASE/termux/service/run" "$SVC/run"
cp "$BASE/termux/service/log-run" "$SVC/log/run"
chmod 700 "$SVC/run" "$SVC/log/run"
rm -f "$SVC/down"

# 8. Start if needed. Do not restart a running daemon by default: when this
#    script is invoked over the tailnet, the SSH session is carried by it.
SERVICE_RUNNING=0
if SVDIR="$SVDIR" sv status "$SVCNAME" 2>/dev/null | grep -q '^run:'; then
  SERVICE_RUNNING=1
  if [ "$TAILNET_RESTART" = "1" ]; then
    SVDIR="$SVDIR" sv restart "$SVCNAME"
    SERVICE_RUNNING=0
  fi
else
  if ! pgrep -f runsvdir >/dev/null 2>&1; then
    echo "WARN: runsvdir is not running; the service will start with the next Termux session." >&2
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    SVDIR="$SVDIR" sv up "$SVCNAME" 2>/dev/null && break
    sleep 1
  done
fi

i=0
while [ "$i" -lt 40 ]; do
  [ -S "$SOCK" ] && break
  sleep 0.5
  i=$((i + 1))
done

# 9. CLI helper. PATH= is required on Android: Go's faccessat2 is blocked by
#    seccomp and would otherwise kill the CLI at startup.
ts() { ( PATH= exec "$TSDIR/tailscale" --socket="$SOCK" "$@" ); }

# 10. Log in only when the node has no IP yet.
if ! ts ip >/dev/null 2>&1; then
  if [ -n "$CONTROL_URL" ] && [ -s "$AUTH_KEY_FILE" ]; then
    say "logging in to $CONTROL_URL"
    ts up --login-server="$CONTROL_URL" \
      --auth-key="file:$AUTH_KEY_FILE" \
      --accept-dns="$ACCEPT_DNS" --accept-routes="$ACCEPT_ROUTES" \
      --hostname="$NODE_HOSTNAME" --timeout=90s || true
  else
    echo "WARN: skipped login (CONTROL_URL and auth key are required for first login)" >&2
  fi
fi

# 11. Expose the local SSH port to the tailnet (stored in daemon state).
case "$SSH_PORT" in
  ''|*[!0-9]*) echo "WARN: invalid SSH_PORT=$SSH_PORT; skipping serve" >&2 ;;
  0) ;;
  *) ts serve --bg --tcp "$SSH_PORT" tcp://localhost:"$SSH_PORT" >/dev/null 2>&1 || true ;;
esac

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock || true
fi

say "node IP: $(ts ip 2>/dev/null || echo '(not logged in)')"
say "runit status:"
SVDIR="$SVDIR" sv status "$SVCNAME" || true
say "serve status:"
ts serve status 2>/dev/null || true

if [ "$SERVICE_RUNNING" = "1" ]; then
  say "service is already running; if binaries changed, restart with:"
  say "  SVDIR=$SVDIR sv restart $SVCNAME"
fi
