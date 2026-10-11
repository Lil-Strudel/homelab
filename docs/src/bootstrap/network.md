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
   (`enforce_firewall = false` in `terraform/main.tf`). Apply once — nothing is blocked
   yet — verify each flow in the
   [firewall matrix](../reference/network.md#firewall), then set it back to `true` and
   apply again. Run Terraform from the Management VLAN, since enforcement restricts
   router admin to Management and `wg-management`.
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

# Bare id for a single object (e.g. a bridge port on ether5):
:foreach i in=[/interface/bridge/port find where interface=ether5] do={:put $i}
```

Substitute the printed `*X` ids into the import commands, then run the script.

## Router-side BGP peers

On the router, add a BGP connection **per node** (all seven) — Terraform recreates these
from `bgp_peers` in `terraform/main.tf`, so this is really just what an apply sets up:

- **AS:** `65100` (the router's own); **remote AS:** `65000` (the cluster)
- **Remote address:** the node IP — control plane `10.69.60.11`/`.12`/`.13`,
  workers `10.69.60.21`/`.22`/`.23`/`.24`
- **Local role:** `ebgp`

On RouterOS 7.22 and later, Terraform can't **create** a peer: the provider still sends
`add-path-out`, which RouterOS removed
([terraform-provider-routeros#959](https://github.com/terraform-routeros/terraform-provider-routeros/issues/959)).
Until that's fixed, add the `bgp_peers` entry, create the connection on the router with
the same settings as an existing peer, and import it:

```
/routing/bgp/connection add name="<NAME> Peer" instance=bgp-instance-1 as=65100 local.role=ebgp \
  remote.address=<NODE_IP>/32 remote.as=65000 output.default-originate=always routing-table=main \
  connect=yes listen=yes afi=ip nexthop-choice=default keepalive-time=30s hold-time=1m30s \
  local.port=179 remote.port=179
```

```bash
terraform import 'module.router.routeros_routing_bgp_connection.peer["<NAME> Peer"]' '<ID>'
```

`<ID>` is the `*N` from `/routing/bgp/connection print`. The module ignores `add_path_out`
and `router_id`, so `terraform plan` stays clean once the connection is imported.

That's the whole router side. Once the cluster is up, the control-plane VIP route and a
`/32` per service in `10.69.65.0/24` appear automatically — kube-vip advertises the VIP,
Cilium advertises services (see
[Architecture → Load balancing](../architecture.md#load-balancing--the-control-plane-vip)).
Those `/32`s are the only way the services range exists on the network, so nothing about
it needs a VLAN, an address, or a DHCP server on the router.
