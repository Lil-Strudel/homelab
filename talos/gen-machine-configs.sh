mkdir -p machine-patches
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/mai-1-patch.yaml --output machine-configs/mai-1.yaml
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/mai-2-patch.yaml --output machine-configs/mai-2.yaml
talosctl machineconfig patch talos/controlplane.yaml --patch @machine-patches/mai-3-patch.yaml --output machine-configs/mai-3.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-1-patch.yaml --output machine-configs/rem-1.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-2-patch.yaml --output machine-configs/rem-2.yaml
talosctl machineconfig patch talos/worker.yaml --patch @machine-patches/rem-3-patch.yaml --output machine-configs/rem-3.yaml
