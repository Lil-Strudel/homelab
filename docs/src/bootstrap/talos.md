# 2. Talos Cluster

Bring up the OS and Kubernetes control plane. Versions (Talos, Kubernetes) are in
[Reference → Versions](../reference/versions.md); the design is in
[Architecture → Talos](../architecture.md#2-operating-system--talos-linux).

Get the Secure Boot ISO for the pinned Talos version from the
[Talos factory](https://factory.talos.dev/?arch=amd64&board=undefined&cmdline-set=true&extensions=-&platform=metal&secureboot=true&target=metal),
schematic `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` (Secure
Boot, default extensions) — the same schematic pinned as the installer image in
`talos/patch.yaml`.

> **First bring-up only:** the control-plane VIP (`10.69.60.10`) is owned by kube-vip,
> which isn't running yet. Set a temporary dst-nat on the MikroTik pointing
> `10.69.60.10` → `10.69.60.11` so the endpoint resolves during bootstrap; remove it
> once kube-vip is up.

From `talos/`:

```bash
./gen-talos-objects.sh     # secrets + controlplane/worker/talosconfig from patch.yaml
./gen-machine-configs.sh   # per-node machine-configs/
```

Boot each node into the Talos ISO, enrol the Secure Boot keys on the boot page, then
boot the ISO again. Apply the config to each node:

```bash
talosctl apply-config --insecure -n 10.69.60.11 --file machine-configs/makima-1.yaml
```

...or, if Talos is already installed and every node is in maintenance mode:

```bash
./apply-config-all-nodes.sh
```

Bootstrap etcd on the first control-plane node, then pull the kubeconfig:

```bash
talosctl bootstrap  -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
talosctl kubeconfig -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
```

Nodes stay `NotReady` until a CNI is installed — continue to
[Cilium + Flux](./cluster.md).
