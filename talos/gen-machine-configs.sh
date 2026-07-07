#!/usr/bin/env bash
# Generate per-node machine configs from the base control-plane/worker configs.
# Requires ./gen-talos-objects.sh to have been run first (it produces the
# gitignored talos/controlplane.yaml and talos/worker.yaml from the encrypted secrets).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f talos/controlplane.yaml ] || [ ! -f talos/worker.yaml ]; then
  echo "talos/controlplane.yaml or talos/worker.yaml missing — run ./gen-talos-objects.sh first" >&2
  exit 1
fi

mkdir -p machine-configs
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/makima-1-patch.yaml --output machine-configs/makima-1.yaml
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/makima-2-patch.yaml --output machine-configs/makima-2.yaml
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/makima-3-patch.yaml --output machine-configs/makima-3.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-1-patch.yaml --output machine-configs/rem-1.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-2-patch.yaml --output machine-configs/rem-2.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-3-patch.yaml --output machine-configs/rem-3.yaml
