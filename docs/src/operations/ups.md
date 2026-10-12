# UPS (APC NMC3)

Two APC UPSes, each managed through an AP9641 Network Management Card 3 (NMC3) on the
Management VLAN. Models and addresses are in
[Reference → Systems](../reference/systems.md#out-of-band--power); firmware versions are in
[Reference → Versions](../reference/versions.md).

| UPS | Card hostname | IP | Switch port |
| --- | --- | --- | --- |
| SMT1000RM2UC | `ups-smt1000` | `10.69.100.40` | 10G switch `ether7` |
| SMX1500RM2UCNC | `ups-smx1500` | `10.69.100.41` | 10G switch `ether8` |

The cards stay on DHCP; their addresses are pinned by MAC as `mgmt-40` / `mgmt-41` in
`terraform/main.tf`. Metrics flow through the in-cluster `snmp-exporter` — see
[Observability → UPSes](./observability.md#upses).

## Card configuration as code

The cards cannot be driven by Terraform, but they accept a partial `config.ini` uploaded
over SCP and apply it themselves. That is the declarative surface:

| File | Holds |
| --- | --- |
| `hardware/ups/common.ini` | Everything both cards share: DNS, NTP, timezone, SNMPv3, disabled services (syslog included), login lockout |
| `hardware/ups/<ups>.ini` | Per-card identity: hostname, system name, location, UPS name |
| `hardware/nmc.sops.yaml` | The cards' admin login (`username`, `password`) |
| `kubernetes/…/snmp-exporter/secret.sops.yaml` | The SNMPv3 user and passphrases — the one source for both the cards and the exporter |

`hardware/ups/nmc.sh` renders the `${…}` placeholders from SOPS into a temp directory and
works against one or more cards:

```bash
hardware/ups/nmc.sh diff                  # both cards: live config vs. declared, like a plan
hardware/ups/nmc.sh apply smx1500         # upload common.ini then smx1500.ini, show the card's verdict, re-diff
hardware/ups/nmc.sh push smt1000         # upload only — no event log, no config.ini, no diff
hardware/ups/nmc.sh diff smt1000@10.69.100.248   # override the IP, e.g. before the reservation is applied
```

**Never `diff` or `apply` the SMT1000's card — use `push`.** See
[The SMT1000 card hangs](#the-smt1000-card-hangs) below; verify it over SNMP instead
(`sysName`, `sysLocation`, and a working scrape prove both files landed).

`diff` exits non-zero on drift and prints `[Section] Key: live -> declared`. Only keys in
the `.ini` files are managed; everything else on the card (outlet groups, UPS transfer
voltages, sensitivity, self-test schedule, the audible alarm) is left as found.

### What the declared settings are, and why

| Setting | Value | Why |
| --- | --- | --- |
| SNMPv1 | off | Community strings are cleartext. |
| SNMPv3 | `authPriv`, SHA-1 + AES-128 | The strongest pair the free 2.x firmware offers; SHA-256/AES-256 are SNS-only. |
| SNMPv3 access 1 | `10.69.60.255` | The Trusted VLAN — `255` octets are the card's wildcard. Scrapes arrive from node addresses because pod egress is SNAT'd. |
| SNMPv3 access 2 | `10.69.100.255` | The Management VLAN, so the admin plane can poll a card directly when debugging. |
| Syslog | off | The card starts each message with a numeric `MM/DD/YYYY` date instead of an RFC 3164 timestamp, so `alloy-syslog` rejects every line. Accepting it would take Alloy's experimental `raw` mode; SNMP already carries the transfer cause and self-test result, and the full event log stays on the card (`event.txt` over SCP). |
| DNS, NTP | `10.69.100.1` | The router serves both to every VLAN. |
| Timezone | UTC, DST off | The card has no tz database and its DST token is undocumented; Grafana and Loki show local time anyway. |
| IPv6 | off | Nothing on the LAN runs IPv6. |
| FTP, Telnet, HTTP, BACnet | off | Unused surfaces; HTTPS (TLS 1.2+) and SSH/SCP stay on. |
| Bad-login lockout | 5 attempts | 2.5.5.1 raised the default to 10. |

### Card quirks the script works around

- **One `.ini` at a time.** The card applies an upload asynchronously and rejects another
  while it is busy (`A configuration file is currently being processed`), so `nmc.sh`
  waits after each file.
- **`scp` exits non-zero on success.** The card drops the SCP session uncleanly; the script
  judges a download by whether the file arrived.
- **Legacy SCP only.** Uploads need `scp -O`; the card has no SFTP subsystem.
- **Passphrases are write-only.** `UserProfile1AuthPhrase` / `EncryptPhrase` are accepted
  but never exported, so `diff` skips them — a working scrape is the proof they match.
- **`BootMode` is rejected.** `BootMode=DHCP Only` is how the card exports the value, yet
  uploading it logs `Invalid value`; DHCP is the factory default, so it is not declared.
- **The admin password cannot be set by `config.ini`.** It is set once by hand (or by the
  first-login prompt after a format) and recorded in `hardware/nmc.sops.yaml`.

The card's verdict on an upload is in its event log, not a result file:
`Configuration file upload complete, with <n> valid values` or
`Configuration file warning: Invalid … on line <n>`. `nmc.sh apply` prints those lines.

## Firmware

**NMC firmware.** The free branch ends at 2.5.x: 3.x needs a Secure NMC System
subscription and its own upgrade tool. Downloads come straight from Schneider's CDN —
`https://download.se.com/files?p_Doc_Ref=APC_NMC3_SU_EN` returns a zip with the
self-extracting `.exe`; inside it, `Bins/apc_hw21_su_<version>.nmc3` is the one file to
upload (it carries the boot monitor and the application together):

```bash
scp -O apc_hw21_su_<VERSION>.nmc3 <user>@<card>:apc_hw21_su_<VERSION>.nmc3
```

Only the card reboots; the UPS output is untouched. A healthy card is back in about two
minutes. Settings survive, but new firmware can change defaults — run `nmc.sh diff`
afterwards.

**UPS firmware.** Signed `.enc` files are in the
`https://download.se.com/files?p_Doc_Ref=Smart-UPS_FW_Release_Notes` bundle, named by the
UPS's ID (`upsabout` shows it, e.g. `ID1015`). Upload through the card's web UI
(*Configuration → Firmware Update*) or CLI (`scp` to `/tmp`, then
`upsfwupdate -install -file "/tmp/<file>"`). Schneider's FA170679 table says whether a
model can update with its output on: the SMT1000 (ID1015) can; the SMX1500 (ID1050)
**cannot** — its update drops the load, so it needs a planned outage of whatever it
powers.

## Recovery

### The SMT1000 card hangs

The AP9641 in the SMT1000 hangs — link up, nothing transmitted — after either of two
things, while the identical card in the SMX1500 does both without trouble:

- **Generating `config.ini`.** The export makes the card read every setting from the UPS
  over its internal link, and this card did not survive one or two of them.
- **A warm reboot** — the one after a firmware upload, or the `reboot` command. It only
  comes back from a cold start (a reseat).

Plain SNMP polling is fine: 30 polls over 15 minutes after configuration, and untouched
uptime well past the point where an export kills it. That is everything the cluster does
with it, so the card is in service with `push` as its only write path. Started after its
NMC firmware upgrade and did not change with the UPS firmware update or a `format`;
candidates if it gets worse are UPS firmware 18.0 (the latest for ID1015, updatable with
output on) and a warranty claim on the card.

A hung card keeps its link up but sends nothing: the switch port's `rx-bytes` stops
moving, the card's MAC drops out of the bridge host table, and its DHCP lease expires. The
activity light still blinks, because the switch keeps transmitting to it. The UPS keeps
powering its load throughout — the card is a management add-on.

1. **Reseat the card.** The SmartSlot is hot-swap; pulling the card reboots it without
   touching the outlets.
2. **Format it** if it keeps hanging. Cards that ran firmware older than 2.3.1.1 can carry a
   corrupted internal database across upgrades (Schneider FAQ000262012). In the CLI:
   `format`, answer `YES`, then `reboot` (or reseat). Over a scripted SSH session, type
   the `YES` one character at a time — a pasted `YES\r\n` arrives as `YE` and cancels.
3. After a format the card is factory-fresh: DHCP, a new TLS certificate and SSH host key
   (expect a host-key warning), and the default admin login, which must be changed on
   first login — set it back to the password in `hardware/nmc.sops.yaml`. Then
   `nmc.sh apply <ups>` restores everything declared.
4. If the card never comes back on the network, the micro-USB console (57600 8N1) reaches
   the boot monitor, which can take the `.nmc3` file over XMODEM.

## History

What has been done to the cards by hand, in order. Anything not listed is either declared
in `hardware/ups/` or factory default.

| Date | Card | Change |
| --- | --- | --- |
| 2026-10-11 | both | First contact: both on DHCP (`.251`, `.252`), SNMP/NTP/DNS/syslog unconfigured, hostnames `apc<MAC>`. |
| 2026-10-11 | `ups-smx1500` | NMC firmware 2.5.0.8 → current (Versions). Clean, ~2 min. |
| 2026-10-11 | `ups-smt1000` | NMC firmware 2.0.0.6 → current. Card hung after the upload and needed a reseat. |
| 2026-10-11 | `ups-smt1000` | UPS firmware 04.1 → current (Versions), updated by hand. Side effects: audible alarm turned on (was off); battery SKU now reads `APCRBC157`. |
| 2026-10-11 | `ups-smx1500` | `nmc.sh apply` — declared config applied; in sync. |
| 2026-10-11 | `ups-smt1000` | Hung twice more within minutes of boot; `format` staged per FAQ000262012. |
| 2026-10-11 | `ups-smx1500` | Syslog to `alloy-syslog` tried and turned off — see the Syslog row above. |
| 2026-10-11 | `ups-smx1500` | SNMPv3 scrape verified from Management with the exporter's credentials. |
| 2026-10-11 | `ups-smt1000` | Reseated; `format` completed on that cold boot. Admin password reset from factory to `hardware/nmc.sops.yaml`. Hung again after one `config.ini` export. |
| 2026-10-11 | `ups-smt1000` | Reseated; `nmc.sh push` equivalent (upload only). SNMPv3 verified: 30/30 polls over 15 min, `sysName` `ups-smt1000`. |
