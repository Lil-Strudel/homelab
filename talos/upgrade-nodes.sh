#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

version=${1:?usage: ./upgrade-nodes.sh <talos-version> [node...]}
installer_in() { grep -oP 'factory\.talos\.dev/metal-installer[a-z-]*/[0-9a-f]+' "$1"; }
installer() { installer_in "machine-patches/$1-patch.yaml" || installer_in patch.yaml; }

declare -A ips=(
  [makima-1]=10.69.60.11 [makima-2]=10.69.60.12 [makima-3]=10.69.60.13
  [rem-1]=10.69.60.21 [rem-2]=10.69.60.22 [rem-3]=10.69.60.23 [rem-4]=10.69.60.24
)
nodes=("${@:2}")
(( ${#nodes[@]} )) || nodes=(makima-1 makima-2 makima-3 rem-1 rem-2 rem-3 rem-4)

ceph() { kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph "$@"; }
log() { echo "$(date +%T) [$1] ${*:2}"; }
wait_ceph_clean() { until ceph pg stat | awk '{ exit !($1 == $3 && $4 == "active+clean;") }'; do sleep 10; done; }

for name in "${nodes[@]}"; do
  ip=${ips[$name]}
  endpoint=$ip
  [[ $name == rem-* ]] && endpoint=${ips[makima-1]} # workers cannot serve the kubeconfig talosctl needs to drain them
  talos=(talosctl --talosconfig talos/talosconfig -n "$ip" -e "$endpoint")

  if [[ $("${talos[@]}" version --short | awk '/Tag:/{print $2}' | tail -1) == "$version" ]]; then
    log "$name" "already on $version"
    continue
  fi

  wait_ceph_clean
  ceph osd set noout
  trap 'ceph osd unset noout' EXIT
  log "$name" "upgrading to $version"
  "${talos[@]}" upgrade -i "$(installer "$name"):$version" --wait --timeout 30m --progress plain

  ceph osd unset noout
  trap - EXIT
  wait_ceph_clean
  log "$name" "done: $(kubectl get node "$name" -o jsonpath='{.status.nodeInfo.osImage}')"
done
