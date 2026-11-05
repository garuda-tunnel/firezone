# Operator runbook — Firezone client WireGuard stale handshake

## Symptom

A Firezone client cannot reach the hub RouterOS LAN gateway through the
WireGuard tunnel and reports:

```
PING 192.0.2.1 (192.0.2.1) ... 56 data bytes
--- 192.0.2.1 ping statistics ---
N packets transmitted, 0 received, 100% packet loss
```

(i.e. the Firezone client host cannot reach the hub RouterOS LAN gateway through
the Firezone WireGuard tunnel.)

## Class

**Operational fixture drift** — NOT a code regression. The Firezone client
holds a `wg0.conf` whose `Endpoint=` peers to a stale hub public IP. The hub VM
has since been recreated (e.g. by `terragrunt apply` recreating the VM when
its module source pin changes), and the new hub public IP is different.
WireGuard then cannot complete a fresh handshake, the tunnel stays half-open,
and tunnel-routed pings drop.

This is fixture drift on the **fz-client side**: the umbrella, components, and
RouterOS state are all healthy.

## Quick diagnosis (3 commands)

Run on the fz-client host:

```bash
# 1. Last successful handshake — if older than a few minutes, the tunnel is stale
sudo wg show

# 2. Firezone server-side wg interface — confirm no rx/tx vs this peer
kubectl -n garuda exec <firezone-pod> -c firezone -- \
  cat /proc/net/dev | grep wg-firezone

# 3. Endpoint IP the client is dialing vs. the actual hub public IP
sudo grep -E '^Endpoint' /etc/wireguard/wg0.conf
# compare against the current hub VM public IP from your infra outputs
```

If (1) shows `latest handshake: <hours/days ago>` and (3) shows an
`Endpoint=<IP>:<port>` that does NOT match the current hub public IP, you have
fixture drift.

## Fix

### Option 1 (recommended) — re-issue the device through Firezone Admin UI

1. Browse to the Firezone admin: `https://hub.example.net/admin/devices`.
2. Locate the `fz-client` device, delete it, and create a new device for the
   same user.
3. Download the freshly generated `.conf`.
4. Replace it on the fz-client host (the path depends on how the client is
   deployed; for the Docker-based client it is the bind-mounted file inside
   the `wg-client` container — `docker inspect wg-client` shows the mount).
5. Restart the client:

   ```bash
   docker restart wg-client
   ```

### Option 2 — manual edit of `Endpoint=`

If admin UI access is unavailable, the minimum drift fix is to rewrite only
the `Endpoint=` line:

1. On the fz-client host, find the active `wg0.conf` (under the Docker
   volume / bind mount referenced by `docker inspect wg-client`).
2. Replace `Endpoint=<old_ip>:<port>` with the current hub public IP, keeping
   the same port.
3. Restart the client: `docker restart wg-client`.

Note: this works only because the WireGuard keys are unchanged. If the
Firezone server has rotated the peer key, Option 1 is mandatory.

## Verification

```bash
# Fresh handshake (<1 min ago)
sudo wg show

# Confirm the deployed unit has no drift.
terragrunt plan -detailed-exitcode
```

## Prevention

Whenever `terragrunt apply` on any stand recreates the
hub VM, the hub public IP can change. Add an operator step to the apply
runbook:

> After any apply that recreates the hub VM, re-issue the `fz-client` device
> from the Firezone admin UI and refresh the client `.conf`.

A longer-term fix is to give the hub a stable allocated public IP (so VM
recreation no longer changes the address) and/or to have the Firezone
configuration encode the hub by DNS name resolved at handshake time rather
than a baked-in `Endpoint=<IP>`. Both are out of scope of any in-flight
sub-project at the time of this runbook.
