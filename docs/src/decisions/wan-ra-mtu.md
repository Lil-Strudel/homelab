# WAN RA MTU Syslog

The router's upstream neighbour advertises an MTU our WAN link cannot use, and RouterOS
logs a warning every time it does — roughly **2,030 times an hour, indefinitely**. The
message is correct, the condition is real, and there is nothing on this network that can
fix it. It is dropped at the shipper so it does not bury the rest of the router's syslog.

## The message

```
invalid mtu 9192 on ether1 from fe80::21c:73ff:fe00:99
```

It arrives from `router` at `severity=warning`, is byte-identical every time, and is the
only form it takes — a 5,000-line sample normalised to exactly one template.

## What it actually is

`ether1` is the **WAN uplink** (`wan_interface` in `terraform/main.tf`), so the sender sits
on the ISP side of the handoff, not on any segment described in
[Reference → Network](../reference/network.md).

The source is an IPv6 link-local address in EUI-64 form, which encodes the sender's MAC.
Reverse it by splitting off the middle `ff:fe` and flipping bit 1 of the first byte:

```
fe80::21c:73ff:fe00:99
      02 1c 73 ff fe 00 00 99   →  strip ff:fe  →  02:1c:73:00:00:99
      flip the universal/local bit in the first octet  →  00:1c:73:00:00:99
```

OUI `00:1C:73` belongs to **Arista Networks** — carrier aggregation hardware rather than a
consumer CPE. Re-verify the OUI against the IEEE registry if it matters; the MAC
derivation above is exact regardless.

That device sends IPv6 Router Advertisements carrying an **MTU option of 9192**, a jumbo
value valid inside their fabric. Our `ether1` runs a smaller MTU, so RouterOS rejects the
option as unusable and logs it. Rejecting it is the correct behaviour: honouring an MTU
larger than the link supports would black-hole traffic. The RA is otherwise processed
normally, so nothing is degraded.

The only genuinely odd part is the **rate**. RAs are normally sent every few hundred
seconds; this arrives about **0.57 times per second**, flat, with no diurnal shape and no
step changes. That is the upstream device's behaviour and is not observable from here
beyond the log line itself.

## Why it is dropped rather than fixed

It cannot be fixed from this network — the sender is not ours, and the receiving behaviour
is already correct. Left alone it accounted for **88% of all MikroTik syslog**, which is
the actual harm: a real router message becomes one line in nine.

`alloy-syslog` drops it before it reaches Loki:

```alloy
stage.drop {
  expression          = "invalid mtu [0-9]+ on ether1 from fe80::"
  drop_counter_reason = "routeros_wan_ra_mtu"
}
```

The expression is deliberately narrow. It is pinned to `ether1` and to an IPv6 link-local
sender, so an MTU complaint about any **other** interface, or from a global address, still
ships. It leaves the MTU value itself open (`[0-9]+`) so a change upstream does not
silently reopen the flood — the counter moves instead of the log.

## Seeing them again

The lines still exist on the router; only the copy in Loki is suppressed.

**On the device** — the full history, unfiltered:

```bash
/log print where message~"invalid mtu"
```

**How often it is still firing**, without turning the filter off. `alloy-syslog` exposes
the drop counter on its own metrics port:

```bash
curl -s http://10.69.65.43:12345/metrics \
  | grep 'loki_process_dropped_lines_total.*routeros_wan_ra_mtu'
```

This counter is **not** in VictoriaMetrics — there is no `VMServiceScrape` for the Alloy
releases, so the endpoint has to be read directly. Adding one would put the drop rate on a
dashboard, which is the natural follow-up if this ever needs watching rather than ignoring.

**To see the raw lines in Loki again**, comment out the `stage.drop` block; the shipper
reloads and the next RA is stored. Nothing is retroactive — lines dropped while the filter
was active were never written and cannot be recovered from Loki.

## If the message changes

A different interface, a different sender, or an MTU complaint from a global address will
**not** match the expression and will appear in Loki normally. Treat that as new
information rather than more of the same: it would mean the upstream handoff changed, or
that something inside the network started advertising MTUs.
