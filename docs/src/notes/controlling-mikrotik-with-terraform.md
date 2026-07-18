# Controlling Mikrotik with Terraform

- Make sure all MikroTiks are plugged into a completely different router (this solve alot of the chicken and egg problems with having ip-ing setup)
- Factory Reset MikroTik (don't keep users, no default config, do not backup)
- Login (username: admin password: )
- Make new password
- Disconnect and sign in with new password
- Copy initialize script into terminal line by line
- Disconnect and sign in with new user and ip
- Make sure your admin Age key is present at `~/.config/sops/age/keys.txt` (secrets are read via SOPS — see [Secrets with SOPS + Age](./secrets-with-sops.md))
- Run terraform init
- Change terraform cloud execution to local (required so the SOPS provider can read the Age key)
- Run terraform import script
- Before any major firewall rule change, change all drop firewall rules to disabled.
- Run terraform apply
- Congrats! Your MikroTik is now managed by terraform

## Importing existing RouterOS objects

`scripts/tf_import_mikrotik.sh` is the import script. RouterOS resources import by
their **internal id** (`*X` — a hex handle), not by name, and `/… find` returns
those ids in an ambiguous order. So to write a correct `tf import ... '*X'` line
you first have to map each id to the object it belongs to. On the relevant device,
print id-alongside-name with a `foreach`:

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

> **Gotcha:** `SprinklerAct` is an inline wifi config on AP1 (security/channel
> baked into the single object), unlike the shared `Strudel` network which uses
> separate channel/security objects — so it imports as one `routeros_wifi_configuration`
> resource, not the module's split resources.
