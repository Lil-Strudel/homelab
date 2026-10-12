#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage="usage: ./nmc.sh <diff|apply|push> [ups[@ip]...]"
action=${1:?$usage}
[[ $action == diff || $action == apply || $action == push ]] || { echo "$usage" >&2; exit 2; }

declare -A ips=([smt1000]=10.69.100.40 [smx1500]=10.69.100.41)
targets=("${@:2}")
(( ${#targets[@]} )) || targets=(smt1000 smx1500)

snmp_secret=../../kubernetes/infrastructure/platform/controllers/snmp-exporter/secret.sops.yaml
secret() { sops -d --extract "$2" "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

user=$(secret ../nmc.sops.yaml '["username"]')
NMC_PASSWORD=$(secret ../nmc.sops.yaml '["password"]')
printf '#!/bin/sh\nprintf "%%s\\n" "$NMC_PASSWORD"\n' > "$work/askpass"
chmod 700 "$work/askpass"
export NMC_PASSWORD SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force

SNMP_USERNAME=$(secret "$snmp_secret" '["stringData"]["username"]')
SNMP_AUTH_PHRASE=$(secret "$snmp_secret" '["stringData"]["auth-passphrase"]')
SNMP_PRIV_PHRASE=$(secret "$snmp_secret" '["stringData"]["priv-passphrase"]')
export SNMP_USERNAME SNMP_AUTH_PHRASE SNMP_PRIV_PHRASE

# -O: the card speaks only the legacy SCP protocol. It also drops the session uncleanly, so scp
# exits non-zero even on success; a download is judged by whether the file arrived.
scp_opts=(-O -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
scp_from() { rm -f "$3"; scp "${scp_opts[@]}" "$user@$1:$2" "$3" || true; [[ -s $3 ]] || { echo "could not fetch $2 from $1" >&2; exit 1; }; }
scp_to() { scp "${scp_opts[@]}" "$1" "$user@$2:$3" || true; }

render() { envsubst '$SNMP_USERNAME $SNMP_AUTH_PHRASE $SNMP_PRIV_PHRASE' < "$1.ini" > "$work/$1.ini"; }

drift() {
  python3 - "$@" <<'EOF'
import configparser, sys

def load(path):
    ini = configparser.ConfigParser(interpolation=None, strict=False, delimiters=("=",), comment_prefixes=(";",))
    ini.optionxform = str
    ini.read(path, encoding="latin-1")
    return ini

live = load(sys.argv[1])
drifted = False
for path in sys.argv[2:]:
    want = load(path)
    for section in want.sections():
        for key, value in want[section].items():
            if key.endswith("Phrase"):  # write-only: the card never exports passphrases
                continue
            have = live.get(section, key, fallback=None)
            if have is None or have.strip('"').lower() != value.lower():
                print(f"  [{section}] {key}: {have} -> {value}")
                drifted = True
sys.exit(drifted)
EOF
}

status=0
for target in "${targets[@]}"; do
  ups=${target%@*}
  ip=${ips[$ups]:?unknown ups: $ups}
  [[ $target == *@* ]] && ip=${target#*@}
  render common
  render "$ups"

  if [[ $action == apply || $action == push ]]; then
    for file in common "$ups"; do
      scp_to "$work/$file.ini" "$ip" "$file.ini"
      echo "$ups ($ip): uploaded $file.ini"
      sleep 15 # the card applies an .ini asynchronously and rejects another until it finishes
    done
    [[ $action == push ]] && continue
    scp_from "$ip" event.txt "$work/event.txt"
    echo "$ups ($ip):"
    grep -i -m4 "configuration file" "$work/event.txt" | sed 's/^/  /'
  fi

  scp_from "$ip" config.ini "$work/live.ini"
  if drift "$work/live.ini" "$work/common.ini" "$work/$ups.ini"; then
    echo "$ups ($ip): in sync"
  else
    echo "$ups ($ip): drifted (live -> declared)"
    status=1
  fi
done
exit $status
