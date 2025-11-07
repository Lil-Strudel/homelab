mkdir -p machine-patches
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/makima-1-patch.yaml --output machine-configs/makima-1.yaml
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/makima-2-patch.yaml --output machine-configs/makima-2.yaml
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/makima-3-patch.yaml --output machine-configs/makima-3.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-1-patch.yaml --output machine-configs/rem-1.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-2-patch.yaml --output machine-configs/rem-2.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-3-patch.yaml --output machine-configs/rem-3.yaml
