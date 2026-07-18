# 1. Network

Bring the MikroTik network under Terraform, then add the router-side BGP peers the
cluster needs. Run from `terraform/`. Design and addressing are in
[Reference → Network](../reference/network.md).

## Adopt a device into Terraform

Do this per device (router, switches, APs):

1. Plug all MikroTiks into a **separate** router first — avoids the IP chicken-and-egg.
2. Factory reset (no users, no default config, no backup).
3. Log in (`admin`, blank password) and set a new password; reconnect with it.
4. Run `scripts/initialize_mikrotik.sh` (DHCP, self-signed certs, enable `www-ssl`,
   RouterOS API on `:6729`) line by line; reconnect on the new user + IP.
5. Ensure your admin Age key is at `~/.config/sops/age/keys.txt` — secrets are read via
   SOPS ([Operations → Secrets](../operations/secrets.md)).
6. `terraform init`.
7. Set Terraform Cloud execution to **Local** (so the SOPS provider can read the Age
   key and reach the LAN).
8. Before any major firewall change, set all drop firewall rules to **disabled**
   (`enforce_firewall = false`).
9. Run the import script (below), then `terraform apply`.

## Importing existing RouterOS objects

`scripts/tf_import_mikrotik.sh` records the `terraform import` commands. RouterOS
resources import by their **internal id** (`*X` — a hex handle), not by name, and
`/… find` returns those ids in an ambiguous order — so first map each id to its object
on the device with a `foreach`:

```routeros
# BGP connections / wifi interfaces / wifi configs (swap the path + get field):
:foreach i in=[/routing/bgp/connection find] \
  do={:put ($i . "  " . [/routing/bgp/connection get $i name])}
:foreach i in=[/interface/wifi find] \
  do={:put ($i . "  " . [/interface/wifi get $i name])}

# Static DHCP leases key by address, not name:
:foreach i in=[/ip/dhcp-server/lease find where dynamic=no] \
  do={:put ($i . "  " . [/ip/dhcp-server/lease get $i address])}

# Bare id for a single object (e.g. a bridge port on wifi3):
:foreach i in=[/interface/bridge/port find where interface=wifi3] do={:put $i}
```

Substitute the printed `*X` ids into the import commands, then run the script.

> **Gotcha:** `SprinklerAct` is an inline wifi config on AP1 (security/channel baked
> into one object), unlike the shared `Strudel` network which uses separate
> channel/security objects — so it imports as one `routeros_wifi_configuration`
> resource, not the module's split resources.

## Router-side BGP peers

On the router, add a BGP connection **per node** (all six) — Terraform recreates these
from `bgp_peers` in `terraform/main.tf`, so this is really just what an apply sets up:

- **Remote AS:** `65100` (the router's own AS; the cluster is `65000`)
- **Remote address:** the node IP — control plane `10.69.60.11`/`.12`/`.13`,
  workers `10.69.60.21`/`.22`/`.23`
- **Local role:** `ebgp`

That's the whole router side. Once the cluster is up, the control-plane VIP route and
the service pool (`10.69.255.0/24`) `/32`s appear automatically — kube-vip advertises
the VIP, Cilium advertises services (see
[Architecture → Load balancing](../architecture.md#load-balancing--the-control-plane-vip)).
