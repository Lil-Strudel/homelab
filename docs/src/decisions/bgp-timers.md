# BGP Timers

Every BGP session in the cluster runs a **90 s hold time** with a **30 s keepalive
interval**, on both ends. These are the only BGP timers that are configured by hand on the
MikroTik rather than by Terraform, and that exception is deliberate — see
[Not managed by Terraform](#not-managed-by-terraform).

## Why the values

A BGP speaker tears a session down when it hears *nothing* from its peer for the duration
of the negotiated hold time. Keeping a session up is therefore the responsibility of the
**sending** side: each end must emit a keepalive comfortably more often than the other
end's hold timer fires. The convention is `keepalive = hold / 3`, which tolerates two lost
keepalives before a teardown.

The negotiated hold time is the **lower** of the two ends' configured values, so the
shorter side wins and the other end's keepalive interval must still fit inside it. Both
ends are therefore configured to the same pair rather than left on their defaults, which
do not agree:

| Speaker | Configured in | Default hold | Default keepalive |
| --- | --- | --- | --- |
| kube-vip (control-plane VIP) | `controllers/kube-vip/kube-vip.yaml` container `args` | 30 s | 10 s |
| Cilium (service IPs) | `configs/cilium/bgp.yaml` | 90 s | 30 s |
| RouterOS (all six peers) | on the device, per connection | 3 m | 3 m |

RouterOS's default keepalive of 3 m is longer than either speaker's default hold, so a
session left on defaults is torn down by the *peer* — the router logs it as an inbound
`code (4,0)` `Hold timer expired` notification, then rebuilds, on a loop. 90/30 is the
pair that satisfies every combination.

## Where each side is set

**kube-vip** carries `--bgpHoldTimer=90` and `--bgpKeepAliveInterval=30` in the container
`args`. Its manifest generator accepts both flags and silently discards them, emitting no
corresponding `env` entry, so they are appended by the generation pipeline — see
[kube-vip Manifest](kube-vip.md#the-bgp-timer-fixup-the-other-edit).

**Cilium** needs no configuration; its defaults already match.

**RouterOS** carries `hold-time=1m30s` and `keepalive-time=30s` on each of the six
`/routing/bgp/connection` entries.

## Not managed by Terraform

`routeros_routing_bgp_connection` in `terraform/modules/router/main.tf` deliberately does
**not** declare `hold_time` or `keepalive_time`, so the repo and the device are knowingly
out of sync on these two fields alone.

The pinned `terraform-routeros` provider (see `required_providers` in `terraform/main.tf`)
reads the peer's add-path setting as `output.add-path` but writes it back as
`add-path-out`, which the router rejects:

```
400 Bad Request, details: 'unknown parameter add-path-out'
```

This affects **both** the update and the create path, so the resource can be read but
never written. The defect stayed invisible for a long time because these devices were
adopted with `terraform import` (`scripts/tf_import_mikrotik.sh`), so Terraform had never
had cause to write one.

Two consequences worth knowing before touching these resources:

- **Adding the attributes produces a clean plan that fails on apply.** The plan renders as
  six ordinary in-place updates; every one returns the 400 above.
- **`-replace` is destructive here.** The destroy succeeds *before* the create fails,
  leaving the peer deleted and un-recreatable by Terraform. Recovering it means rebuilding
  the connection by hand and re-importing it — see
  [Rebuilding a peer by hand](#rebuilding-a-peer-by-hand).

When a provider release fixes the write path, closing the gap is: bump the pin, add both
attributes to the resource, and confirm the plan is a **no-op** — the device already holds
the intended values, so a clean plan is the proof the drift is gone. If the apply still
returns the 400, the fix has not landed.

## Rebuilding a peer by hand

A connection recreated outside Terraform must match the others exactly, or it will show as
a diff forever. Two fields are easy to get wrong:

- `instance` is **mandatory** — creation fails with `missing =instance=` without it.
- `router-id` must be **omitted** — it is deprecated on ROS 7.20+ and rejected as an
  unknown parameter, which is why no live connection carries it.

Afterwards, bring it back under management with `terraform import` against the new object
ID, and verify with a plan that reports no changes.

## Verifying

The router is the authority on what was actually negotiated:

```bash
/routing/bgp/session/print
```

`hold-time` should read `1m30s` on every session. A healthy session's `uptime` climbs
without resetting; the `local.messages` counter incrementing roughly every 30 s is the
direct evidence that the router is meeting its keepalive obligation, since a session can
look established right up until the moment it is torn down.
