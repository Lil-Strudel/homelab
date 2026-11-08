#!/usr/bin/env bash
set -euo pipefail

# Configure the AWS SSO session in ~/.aws/config, log in, then write one profile
# per account the login can reach, named after the account (`StrudeLAN` ->
# `strudelan`). Terraform needs `strudelan` (state) and `lil-strudel` (Route53).
# Values are read from env vars, prompting for any that are unset. Re-running
# rewrites the managed block, so it is safe to run repeatedly and picks up new
# accounts.

: "${SSO_SESSION:=strudel}"
: "${PROFILE_REGION:=us-west-2}"

prompt() {
  local var="$1" msg="$2"
  if [ -z "${!var:-}" ]; then read -rp "$msg: " "$var"; fi
}

prompt SSO_START_URL "SSO start URL (https://<name>.awsapps.com/start)"
prompt SSO_REGION    "SSO region (e.g. us-east-2)"
SSO_START_URL="${SSO_START_URL%/}"

CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"

BEGIN="# >>> homelab aws sso (managed) >>>"
END="# <<< homelab aws sso (managed) <<<"

slug() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

write_block() {
  sed -i "/$BEGIN/,/$END/d" "$CONFIG"
  {
    echo "$BEGIN"
    echo "[sso-session $SSO_SESSION]"
    echo "sso_start_url = $SSO_START_URL"
    echo "sso_region = $SSO_REGION"
    echo "sso_registration_scopes = sso:account:access"
    cat
    echo "$END"
  } >>"$CONFIG"
}

write_block </dev/null
aws sso login --sso-session "$SSO_SESSION"

TOKEN_CACHE="$HOME/.aws/sso/cache/$(printf '%s' "$SSO_SESSION" | sha1sum | cut -d' ' -f1).json"
TOKEN="$(jq -r .accessToken "$TOKEN_CACHE")"

profiles="$(
  aws sso list-accounts --access-token "$TOKEN" --region "$SSO_REGION" --output json |
    jq -r '.accountList | sort_by(.accountName | ascii_downcase)[] | [.accountId, .accountName] | @tsv' |
    while IFS=$'\t' read -r id name; do
      mapfile -t roles < <(
        aws sso list-account-roles --access-token "$TOKEN" --account-id "$id" \
          --region "$SSO_REGION" --output json | jq -r '.roleList[].roleName'
      )
      for role in "${roles[@]}"; do
        profile="$(slug "$name")"
        if [ "${#roles[@]}" -gt 1 ]; then profile="$profile-$(slug "$role")"; fi
        printf '\n[profile %s]\nsso_session = %s\nsso_account_id = %s\nsso_role_name = %s\nregion = %s\n' \
          "$profile" "$SSO_SESSION" "$id" "$role" "$PROFILE_REGION"
      done
    done
)"

write_block <<<"$profiles"

grep -o '^\[profile [^]]*\]' <<<"$profiles" | sed 's/^\[profile \(.*\)\]$/  \1/'
for required in strudelan lil-strudel; do
  grep -q "^\[profile $required\]" <<<"$profiles" ||
    echo "warning: no '$required' profile; Terraform needs it" >&2
done
