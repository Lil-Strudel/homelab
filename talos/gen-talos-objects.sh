#!/usr/bin/env bash
# Generate Talos cluster secrets and the base control-plane/worker/talosconfig.
#
# Secrets are kept encrypted at rest with SOPS + Age (recipients in ../.sops.yaml).
# Plaintext cluster material only ever exists transiently (process substitution)
# or as gitignored generated files under ./talos/.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p talos

# Generate cluster secrets once, then keep only the encrypted copy.
if [ ! -f talos/secrets.sops.yaml ]; then
  talosctl gen secrets -o talos/secrets.sops.yaml
  sops -e -i talos/secrets.sops.yaml
fi

# Generate the base configs from the decrypted secrets (kept in memory only).
# --kubernetes-version pins k8s explicitly so it doesn't float to whatever the
# installed talosctl defaults to. Keep this in sync with the Talos version in
# patch.yaml (Talos v1.13.5 ships Kubernetes 1.36.2 as its default).
talosctl gen config \
  --with-secrets <(sops -d talos/secrets.sops.yaml) \
  --kubernetes-version 1.36.2 \
  strudelnetes https://10.69.60.10:6443 \
  --config-patch @patch.yaml \
  --output ./talos --force

# Keep the committed, encrypted talosconfig in sync with the freshly generated one.
cp talos/talosconfig talos/talosconfig.sops.yaml
sops -e -i talos/talosconfig.sops.yaml
