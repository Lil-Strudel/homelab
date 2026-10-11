#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p talos

if [ ! -f talos/secrets.sops.yaml ]; then
  talosctl gen secrets -o talos/secrets.sops.yaml
  sops -e -i talos/secrets.sops.yaml
fi

# v1.14 emits UnattendedInstallConfig, which patch.yaml and the running nodes don't use
talosctl gen config \
  --talos-version v1.13 \
  --with-secrets <(sops -d talos/secrets.sops.yaml) \
  --kubernetes-version 1.36.5 \
  strudelnetes https://10.69.60.10:6443 \
  --config-patch @patch.yaml \
  --output ./talos --force

cp talos/talosconfig talos/talosconfig.sops.yaml
sops -e -i talos/talosconfig.sops.yaml
