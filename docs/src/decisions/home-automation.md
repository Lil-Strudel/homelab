# Home Automation

Home Assistant, Zigbee2MQTT, Z-Wave JS UI and Mosquitto all run on the cluster, and the
radios they drive do not. The runbook is [Operations → Home Automation](../operations/home-automation.md);
this note is the reasoning behind its shape.

## The radios are network endpoints, not USB devices

Every radio is reached as `tcp://<ip>:<port>`. Zigbee2MQTT and Z-Wave JS UI both accept that
in place of a serial device path and speak the radio's serial protocol over the socket. Nothing
in the cluster knows or cares what is on the other end.

The alternative is plugging the sticks into a node and passing them through with a device
plugin. That pins both workloads to one node, adds a privileged DaemonSet, and turns a node
drain into a radio outage. With network radios, the pods are ordinary Deployments that land on
any worker and reschedule like everything else.

It also matches where the hardware is going. The SONOFF Dongle Max (Zigbee) and Dongle-MZG23
(Z-Wave 800) are each a radio SoC with an ESP32 in front of it that serves the radio's UART
over TCP, powered over PoE. Until they arrive, a Raspberry Pi runs `ser2net` to give the two
USB sticks — a ZBDongle-E and a Dongle-PZG23 — the same interface. Swapping hardware is then a
change of address in two manifests plus a radio migration, not a redesign. The Pi is
deliberately not managed as code: it exists for a few weeks.

`ser2net` runs each port with `kickolduser`. A radio serves one client, and when a pod is
rescheduled the old TCP session can linger half-open; without `kickolduser` the new pod is
refused until it times out.

Both workloads are `replicas: 1` with `strategy: Recreate` for the same reason: two
Zigbee2MQTT instances on one coordinator corrupt the network state.

## The radios sit on Trusted, not IoT

A radio's TCP port has no authentication. Whatever can open it controls the mesh — including
any Z-Wave lock on it. The IoT VLAN exists to hold devices that are not trusted, so putting the
radios there would hand a compromised smart plug the keys to the front door.

On Trusted they are beside the nodes, so pod traffic (SNAT'd to a node address) reaches them
without crossing the router, and no firewall rule is needed. Each bridge's
`CiliumNetworkPolicy` names its radio's `/32` and port, and every other pod in the namespace
has an egress policy that leaves the radios out. A pod elsewhere in the cluster with no egress
policy could still open the port — the same exposure as every other host on Trusted.

## Keys live in SOPS, not only on a volume

The Zigbee network key and PAN IDs, and the six Z-Wave S0/S2/Long Range keys, are what every
paired device is bound to. Lose them and every device has to be re-paired by hand. They are
generated once, committed SOPS-encrypted, and handed to the apps as environment variables, so a
lost PVC costs a restore, not a re-pairing.

Each app has a quirk here:

- **Zigbee2MQTT writes its environment back into `configuration.yaml`.** That is how its
  `ZIGBEE2MQTT_CONFIG_*` overrides work, so the key is also in plaintext on the PVC. That is
  acceptable — the coordinator backup on the same volume holds it too — and the environment
  stays the source of truth on every start. `Z2M_ONBOARD_NO_SERVER` makes a first start write
  `configuration.yaml` from the environment rather than wait behind a setup wizard.
- **Z-Wave JS UI crashes on a fresh store if the Long Range keys come only from the
  environment.** It assigns them into a settings object that does not exist yet. Declaring an
  empty `securityKeysLongRange` in the external settings file (`zwave-js-ui/settings.json`)
  creates that object first. Removing it looks harmless and is not.

## Z-Wave JS UI is configured from a file, and probed over TCP

`ZWAVE_EXTERNAL_SETTINGS` points Z-Wave JS UI at a JSON file from a ConfigMap, which pins the
settings that the cluster depends on: the RF region (USA Long Range, `9`), the Z-Wave JS
websocket server on `3000` that Home Assistant connects to, and service discovery off (mDNS
reaches nothing from a pod). Settings named there are locked in the UI. `ZWAVE_PORT` pins the
radio address the same way.

Its `/health` endpoint is rate-limited per client address at 500 requests an hour, and the
kubelet's probes all come from the node — two probes every 15 to 30 seconds would spend most
of that budget. The probes are TCP instead.

## The recorder is Postgres

Home Assistant's history and long-term statistics go to a CloudNativePG cluster rather than
the default SQLite file. A SQLite database copied by Velero's file-system backup while Home
Assistant writes to it is not reliably restorable, for the same reason a live `PGDATA` is not
(see [Backups](../operations/backups.md#the-postgres-exception)). On Postgres, barman takes
consistent backups with point-in-time recovery, the same way every other app's database is
protected.

## `configuration.yaml` comes from git; everything else is the UI's

Home Assistant mixes YAML with state it manages itself under `.storage/`. The split here:

- **`configuration.yaml` is a ConfigMap**, mounted read-only. It holds only what the
  cluster dictates: the recorder URL (read with `!env_var` from the CNPG-generated Secret)
  and the Prometheus endpoint. A change rolls the pod, because the ConfigMap is generated
  with a content hash.
- **Everything else is the UI's** — location, units, users, integrations, devices,
  automations, scripts, scenes, dashboards — on the PVC, backed up by Velero. Location in
  particular stays out of git: the repo is public.

Home Assistant only creates `automations.yaml`, `scripts.yaml` and `scenes.yaml` when it writes
its own default `configuration.yaml`, which it never does here. An init container `touch`es
them so the `!include`s resolve on the first start.

MQTT and Z-Wave JS are UI-configured integrations — Home Assistant no longer accepts either in
YAML — so they are set up once by hand. Their addresses and credentials are in the runbook.

### Reverse-proxy trust is in storage, not YAML

Home Assistant only accepts `X-Forwarded-For` from proxies it trusts, and answers `400` to
everything else. Cilium's ingress proxy connects from the pod CIDR, so `10.244.0.0/16` has to
be trusted — and nothing wider, or anything in RFC1918 could spoof a client address.

Since 2026.11 that setting lives in `.storage/http`, edited under *Settings → System →
Network → HTTP server*; an `http:` block in YAML is deprecated and stops working in 2027.2.
Home Assistant imports such a block exactly once, as a *trial*: it runs with the new settings
for five minutes and reverts unless someone confirms them in the UI, and it never reads the
YAML again either way. That is a poor fit for GitOps — a missed confirmation leaves the
instance unreachable through the ingress — so the block is not in `configuration.yaml`, and
the setting is made once and carried by the config volume's backup like the rest of
`.storage`. The runbook covers setting it on a fresh volume.

## The image is rootless

`ghcr.io/home-operations/home-assistant` runs Home Assistant without the s6 init system the
upstream image needs root for, so the namespace enforces Pod Security `restricted` like the
other single-purpose namespaces. Every workload in it runs as a non-root user with all
capabilities dropped.

## Home Assistant reaches the internet by port, not by name

Every cloud integration, the version check, and mobile push notifications reach their own
hosts, and that set grows each time an integration is added. An FQDN allowlist would break
integrations silently as they are added, so Home Assistant may reach any public address on
`443`. Private ranges stay excluded, so it still cannot reach the rest of the network.
Zigbee2MQTT and Z-Wave JS UI have short, fixed lists (the OTA index on GitHub; the Z-Wave
device database on npm and the firmware service) and are allowlisted by name.

## No host networking

Home Assistant runs as a normal pod behind an `Ingress`. Discovery protocols (mDNS, SSDP)
cannot leave a pod, but nothing here needs them: the radios carry Zigbee and Z-Wave, and Home
Assistant talks to those apps by Service name.

ESPHome, the next thing planned, does not change that. Home Assistant opens the connection to
an ESPHome device's native API (TCP `6053`), so the devices can stay on the IoT VLAN with no
internet, added to Home Assistant by address, behind a single Terraform rule from Trusted to
IoT on `6053`. Bluetooth works the same way, through ESPHome Bluetooth proxies rather than an
adapter on a node. Matter would be different: it needs IPv6 and a shared L2 segment with its
devices, which means host networking or a second interface on IoT. It is out of scope until
there is a Matter device to justify that.

## Its own Flux Kustomization

`home-automation` reconciles beside `apps`, `media` and `minecraft`, not inside `apps`. The
house's automations should not be held not-Ready by an unrelated app, and the reverse holds
too.

## Zigbee channel 25

Wi-Fi channels are auto-selected on the access points, so any of 1, 6 or 11 may be in use.
Zigbee channel 25 sits above Wi-Fi channel 11, so it overlaps none of them. It is also a
ZLL channel, which older Zigbee Light Link devices require. Changing it later means re-pairing
some devices, so it is pinned in the manifest.
