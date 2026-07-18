#!/usr/bin/env bash
set -euo pipefail

# Configure the AWS SSO session + the two Terraform profiles (strudelan state
# account + lil-strudel Route53 account) in ~/.aws/config, then log in.
# Values are read from env vars, prompting for any that are unset. Re-running
# rewrites the managed block, so it is safe to run repeatedly.

: "${SSO_SESSION:=homelab}"

prompt() {
  local var="$1" msg="$2"
  if [ -z "${!var:-}" ]; then read -rp "$msg: " "$var"; fi
}

prompt SSO_START_URL      "SSO start URL (https://<name>.awsapps.com/start)"
prompt SSO_REGION         "SSO region (e.g. us-west-2)"
prompt SSO_ROLE           "SSO role name / permission set"
prompt STATE_ACCOUNT_ID   "AWS account ID for the 'strudelan' state account"
prompt ROUTE53_ACCOUNT_ID "AWS account ID for the 'lil-strudel' Route53 account"

CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"

BEGIN="# >>> homelab terraform sso (managed) >>>"
END="# <<< homelab terraform sso (managed) <<<"
sed -i "/$BEGIN/,/$END/d" "$CONFIG"

cat >>"$CONFIG" <<EOF
$BEGIN
[sso-session $SSO_SESSION]
sso_start_url = $SSO_START_URL
sso_region = $SSO_REGION
sso_registration_scopes = sso:account:access

[profile strudelan]
sso_session = $SSO_SESSION
sso_account_id = $STATE_ACCOUNT_ID
sso_role_name = $SSO_ROLE
region = us-west-2

[profile lil-strudel]
sso_session = $SSO_SESSION
sso_account_id = $ROUTE53_ACCOUNT_ID
sso_role_name = $SSO_ROLE
region = us-east-1
$END
EOF

aws sso login --sso-session "$SSO_SESSION"
