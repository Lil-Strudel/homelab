#!/usr/bin/env bash
set -euo pipefail

# Write the SOPS-encrypted S3 credentials a CloudNativePG ObjectStore needs, for one app.
#
#   ./scripts/gen_cnpg_backup_secret.sh <app>
#
# The keys come straight out of `terraform output` and are piped into `sops` without ever
# being printed. The plaintext is built in a private temp file and shredded on exit, so it
# never lands in the repo — `sops --filename-override` is what makes the kubernetes/**
# creation rule (admin + cluster keys) apply to a file read from elsewhere.
#
# Re-running rotates nothing; it just re-renders the secret from current Terraform state.

app="${1:?usage: gen_cnpg_backup_secret.sh <app>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/kubernetes/apps/main/$app/postgres-backup-secret.sops.yaml"
region="${AWS_REGION:-us-west-2}"

[ -d "$repo/kubernetes/apps/main/$app" ] || { echo "no such app: $app" >&2; exit 1; }

tmp="$(mktemp)"
chmod 600 "$tmp"
trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT

pick() { python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit("no key for "+sys.argv[1]) if sys.argv[1] not in d else print(d[sys.argv[1]])' "$1"; }

key_id=$(terraform -chdir="$repo/terraform" output -json cnpg_access_key_ids     | pick "$app")
secret=$(terraform -chdir="$repo/terraform" output -json cnpg_secret_access_keys | pick "$app")

cat > "$tmp" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${app}-pg-backup
  namespace: ${app}
type: Opaque
stringData:
  ACCESS_KEY_ID: ${key_id}
  ACCESS_SECRET_KEY: ${secret}
  AWS_REGION: ${region}
EOF
unset key_id secret

sops --config "$repo/.sops.yaml" --filename-override "$target" -e "$tmp" > "$target"

# A failed encrypt that still wrote a file would leave plaintext in a tracked path.
grep -q "ENC\[AES256_GCM" "$target" || { rm -f "$target"; echo "encryption failed" >&2; exit 1; }
echo "wrote $target"
