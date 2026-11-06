# 1. Network

Bring the MikroTik network under Terraform, then add the router-side BGP peers the
cluster needs. Run from `terraform/`. Design and addressing are in
[Reference → Network](../reference/network.md).

## Adopt a device into Terraform

Do this per device (router, switches). Access points have their own flow, below:

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

## Adopt an access point

An AP's permanent uplink is a trunk (10G switch `ether3`/`ether4` to the AP's `ether1`),
which drops untagged frames, so it can't DHCP its way in like the generic flow above.
Instead, reach the AP over a temporary untagged path on its `ether2` and build the trunk
skeleton on `ether1`, then swap cables and import that skeleton. The design is in
[Reference → Network](../reference/network.md#wifi).

1. Temporarily make `ether3`/`ether4` Management access ports in the `ethernet_switch`
   block (`access_ports`, not `trunk_ports`) and apply it with
   `-target=module.ethernet_switch`. Cable each AP's **`ether2`** to its port.
2. Over MAC-WinBox, add the `routeros_username`/`routeros_password` user from
   `terraform/secrets.sops.yaml`, reset with
   `/system/reset-configuration no-defaults=yes skip-backup=yes keep-users=yes`, then add
   `/ip/dhcp-client add interface=ether2`. The AP is now reachable over SSH on a
   Management DHCP lease.
3. Make sure `wifi-qcom` is installed and `wireless` is not. Upgrade both APs to the same
   RouterOS (`/system/package/update/install`), then the firmware
   (`/system/routerboard/upgrade` and reboot). AP1 refuses to provision a CAP on a
   different version.
4. Check `/system/device-mode/print`. If `bandwidth-test` is blocked, the switch module's
   `routeros_tool_bandwidth_server` cannot apply.
5. Paste the bootstrap, with `<IP>` set to `20` for AP1 or `21` for AP2. The VLAN table
   comes before `vlan-filtering`, as the manual warns. The address goes **last**: the
   empty bridge counts as running, so `10.69.100.<IP>/24` gives a second connected route
   for the subnet and cuts the `ether2` session the moment it is added.

   ```routeros
   /certificate add name=root-cert common-name=root-cert key-size=4096 days-valid=3650 key-usage=key-cert-sign,crl-sign
   /certificate add name=tls-cert common-name=tls-cert key-size=4096 days-valid=3650 key-usage=digital-signature,key-agreement,tls-server
   /certificate sign root-cert
   /certificate sign tls-cert ca=root-cert
   /ip/service set www-ssl certificate=tls-cert port=6729 disabled=no

   /interface/bridge add name=bridge vlan-filtering=no
   /interface/bridge/port add bridge=bridge interface=ether1 frame-types=admit-only-vlan-tagged ingress-filtering=yes
   /interface/bridge/vlan add bridge=bridge tagged=bridge,ether1 vlan-ids=100
   /interface/vlan add interface=bridge name=Management_VLAN vlan-id=100
   /interface/bridge set bridge vlan-filtering=yes
   /ip/route add gateway=10.69.100.1
   /ip/address add address=10.69.100.<IP>/24 interface=Management_VLAN
   ```

6. Return `ether3`/`ether4` to `trunk_ports`. Swapping a port between the two lists in one
   apply races (the new bridge port is added before the old one is removed), so first
   apply with `-target` on the two `access_bridge_port` resources, then
   `-target=module.ethernet_switch`.
7. Move each AP's cable from `ether2` to `ether1`, confirm `10.69.100.<IP>` answers, and
   remove the temporary client: `/ip/dhcp-client remove [find interface=ether2]`.
8. Map the ids (below) for each AP's bridge, `Management_VLAN`, address, route, `ether1`
   bridge port, VLAN 100 bridge entry, `wifi1` and `wifi2`. Either fill them into the
   access point block of `scripts/tf_import_mikrotik.sh` and run it, or write them as
   `import` blocks in a throwaway `terraform/imports.tf`, so one plan previews the imports
   together with everything else. Delete the file after the apply.
9. `terraform plan`, then `terraform apply`. The hardening switches the SSH host key to
   ED25519, so clear the old one with `ssh-keygen -R 10.69.100.<IP>`.
10. Verify on AP1: `/interface/wifi/capsman/remote-cap print` lists AP2 as `Ok`,
    `/interface/wifi/monitor [find] once` shows four radios running on the channels in
    `channel_plan`, and a client on `Strudel` gets a `10.69.10.x` lease.

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
