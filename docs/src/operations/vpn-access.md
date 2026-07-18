# VPN Access

Adding a WireGuard client to one of the two tunnels — `wg-home` (personal/trusted) or
`wg-management` (admin). The tunnels themselves, their subnets, and ports are in
[Reference → Network](../reference/network.md#wireguard--remote-access).

## 1. Generate a client keypair

On the client (or with the WireGuard CLI):

```bash
wg genkey | tee client.key | wg pubkey > client.pub
```

The private key stays on the client; only the **public** key goes to the router.

## 2. Register the peer

Add an entry to `wg_home_peers` or `wg_management_peers` in `terraform/main.tf`, keyed by
a stable name. `address` is the next free `/32` in that tunnel's subnet (`.1` is the
router):

```hcl
wg_home_peers = {
  phone = {
    public_key = "<client.pub>"
    address    = "10.69.70.2/32"
  }
}
```

Then apply from `terraform/`:

```bash
terraform apply
```

An optional `preshared_key` (`wg genpsk`) adds a symmetric layer — set it on the peer
and mirror it in the client config's `[Peer] PresharedKey`.

## 3. Build the client config

Pull the server's public key from the Terraform output (`wg_home_public_key` /
`wg_management_public_key`):

```ini
[Interface]
PrivateKey = <client.key>
Address    = 10.69.70.2/32      # the /32 assigned above
DNS        = 10.69.70.1         # the tunnel's router IP

[Peer]
PublicKey  = <wg_home_public_key output>
Endpoint   = vpn.lilstrudel.io:51820   # tunnel's port; see Network reference
AllowedIPs = 10.69.0.0/16       # split tunnel: LAN only
# AllowedIPs = 0.0.0.0/0        # full tunnel: route all traffic over the VPN
PersistentKeepalive = 25
```

`AllowedIPs` is the client's choice: `10.69.0.0/16` routes only homelab traffic over the
tunnel; `0.0.0.0/0` sends everything (useful on untrusted networks).

The server public key also comes straight from SOPS, without applying — the public key
is derived from the private key:

```bash
sops -d --extract '["wireguard_home_private_key"]' secrets.sops.yaml | wg pubkey
```

## 4. Connect (Linux / NetworkManager)

Drop the config in `/etc/wireguard/` (root-owned, `0600`) and import it as a
NetworkManager connection — the connection name is the filename:

```bash
sudo install -m 600 -o root -g root home-laptop.conf /etc/wireguard/home-laptop.conf
sudo nmcli connection import type wireguard file /etc/wireguard/home-laptop.conf
nmcli connection modify home-laptop connection.autoconnect no   # don't auto-VPN at boot
```

Bring it up or down (or toggle from the desktop's network applet):

```bash
nmcli connection up   home-laptop
nmcli connection down home-laptop
```

Both tunnels route `10.69.0.0/16`, so run **one at a time** — bring the other down before
raising a tunnel, or their routes collide. Non-NetworkManager hosts can use
`wg-quick up <name>` against the same `/etc/wireguard/<name>.conf` instead.

## Notes

- The router's WAN must have a routable public IP. Behind CGNAT/double-NAT, forward the
  tunnel's UDP port upstream.
- `vpn.lilstrudel.io` is a static A record ([`terraform/route53.tf`](../reference/network.md#wireguard--remote-access)).
  If the ISP hands out a dynamic public IP, it needs a DDNS updater or the record (and
  client `Endpoint`s) go stale.
