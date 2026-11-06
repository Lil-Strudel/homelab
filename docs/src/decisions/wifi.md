# WiFi

The access point configuration follows the
[MikroTik WiFi manual](https://manual.mikrotik.com/docs/wireless/wifi.md) and its
[CAPsMAN guide](https://manual.mikrotik.com/docs/wireless/wifi/capsman.md). This page
records the choices that aren't defaults and why. The layout is in
[Reference → Network](../reference/network.md#wifi).

## CAPsMAN, with the manager on an AP

MikroTik directs wifi-qcom deployments to CAPsMAN rather than standalone APs, because
802.11r fast transition needs both APs "managed by the same instance of RouterOS". AP1
runs that instance, so nothing else in the network has to.

CAPsMAN cannot manage its own radios through `configuration.manager=capsman`. The manual
says to bind the same configuration profiles to the local radios instead, so
`access_point_1` sets `wifi1` (5 GHz) and `wifi2` (2.4 GHz) to the same per-band profiles
that the provisioning rules hand to AP2. Both APs therefore broadcast identical BSS
settings, which roaming depends on.

The manager's local radios only show the `R` (running) flag, and only become active
bridge ports, once a client associates. `/interface/wifi/monitor` still reports them as
`running` while they wait, so an idle AP1 radio flagged inactive is normal.

AP2's radios are provisioned as **dynamic** interfaces (`create-dynamic-enabled`). They
are recreated on every join, so nothing may reference them, and nothing does: the
datapath adds them to the bridge.

`upgrade-policy=require-same-version` stops AP1 from provisioning a CAP whose RouterOS
version differs from its own. A mismatched AP2 shows up in AP1's remote-cap list but
broadcasts nothing. Upgrade both APs together, AP1 first.

## Client VLAN through the datapath, not bridge PVIDs

The old configuration made `wifi1` and `wifi2` bridge access ports with a PVID, which
put every WiFi client on Management. wifi-qcom tags client traffic in the driver from the
datapath's `vlan-id`, and the radio joins the bridge on its own, so the PVID approach
is redundant. On a CAP, whose dynamic interfaces can't be bridge ports in Terraform, it
can't work at all.

Each CAP keeps a local `capdp` datapath holding only the bridge, which is the manual's
wifi-qcom CAP example. It resolves the bridge on the CAP, and the `vlan-id` still
inherits from the manager's datapath, because an interface falls through to its
configuration profile for any datapath field it leaves unset. Traffic is forwarded on the
CAP (`traffic-processing=on-cap`, the default), so client traffic never hairpins through
AP1.

## Security

- **WPA2 + WPA3-PSK**: the manual's examples pair them. WPA3-capable clients get SAE and
  mandatory management-frame protection; older clients still connect over WPA2. If a
  device refuses to join, try removing `wpa3-psk` first: some older clients mishandle
  transition mode.
- **802.11r with FT-over-DS**, as in the manual's CAPsMAN example.
- **WPS disabled.** It defaults to `push-button`, and the network has no use for it.

## Channels

- **2.4 GHz: 20 MHz on 1, 6 and 11.** These are the only non-overlapping US channels.
  The radio would otherwise default to its widest supported width and could land between
  them. The Zigbee channel choice relies on this (see
  [Home Automation](home-automation.md#zigbee-channel-25)).
- **5 GHz: up to 80 MHz, DFS skipped.** The US regulatory profile leaves three non-DFS
  80 MHz blocks: 36–48, 149–161 and 165–177, enough for each AP to have its own. DFS
  channels would add room, but a radar detection forces the AP off the channel and
  disconnects its clients.
- **Nightly reselection** (`reselect-time=03:00:00..04:00:00`, the form RouterOS stores).
  Each AP rescans at a random moment inside the window. Two APs that boot together scan
  at the same moment and can land in the same block, which the manual warns about. The
  random window pulls them apart and confines the brief client drop to the night.
- **Country `United States`.** RouterOS defaults to Latvia, whose power limits and
  channel set differ.

## Hardening

The manual notes that APs "are not firewall protected", so the AP module builds on the
switch module and inherits its service hardening: no telnet/ftp/www/api,
ssh/winbox/www-ssl restricted to the admin sources, strong SSH crypto, and MAC services
and neighbor discovery confined to the Management VLAN.
