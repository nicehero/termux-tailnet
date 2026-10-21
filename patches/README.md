# Patches

Source: `vendor/tailscale-1.104.2-src.tar.gz` (official `tailscale.com` tag `v1.104.2`).

| Patch | Applied to `bin/tailscaled-v2` | Purpose |
|---|---|---|
| `0001-dnscache-use-default-resolver.patch` | yes | Make `dnscache` use `net.DefaultResolver`, so `feature/androiddns` (Android `dnsproxyd`) resolves names on Termux, where `/etc/resolv.conf` does not exist. |
| `0002-netmap-addresses-from-allowedips.patch` | yes | Fill peer `Addresses` from single-host `AllowedIPs`; some control servers only ship peer IPs in `AllowedIPs`. |
| `optional-0003-tsaddr-custom-cidr.patch` | no | Teach `tsaddr.IsTailscaleIPv4` about a custom tailnet CIDR via `TS_TAILNET_CIDR`, fixing peer-IP display in `tailscale status` and ping-by-name for ranges outside `100.64.0.0/10`. |

## Rebuild

```bash
tar -xzf vendor/tailscale-1.104.2-src.tar.gz
cd tailscale-1.104.2
patch -p1 < ../patches/0001-dnscache-use-default-resolver.patch
patch -p1 < ../patches/0002-netmap-addresses-from-allowedips.patch

# Optional: also support non-CGNAT tailnet ranges at runtime.
# Build with this patch and start the daemon with TS_TAILNET_CIDR=<cidr>.
# patch -p1 < ../patches/optional-0003-tsaddr-custom-cidr.patch

GOTOOLCHAIN=go1.27.3 GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
  go build -trimpath -buildvcs=false -ldflags="-s -w" \
  -o tailscaled-v2 ./cmd/tailscaled
```

Requires Go 1.27.x (not bundled). The shipped `bin/tailscaled-v2` was built exactly
this way (patches 0001 + 0002, without 0003).

Note: without `-X tailscale.com/version.shortStamp=...` / `longStamp=...`, the
daemon reports `1.104.2-ERR-BuildInfo`; the CLI only prints a version-mismatch
warning.
