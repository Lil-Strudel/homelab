# I am just jogging down some notes of what I have done

- Wifi needs to be enabled in Dell BIOS
- Fresh install of Debian Bookworm. NO SWAP! No additional packages. Not even standard system utilities.
- The nic somehow just works perfect with no driver configuration
- Assigned static ip address in mikrotik

```
sudo apt install vim tmux curl
```

- Set ip forward to 1 as per [k8s docs](https://kubernetes.io/docs/setup/production-environment/container-runtimes/#prerequisite-ipv4-forwarding-optional)

```
# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# should be set to 1
sudo sysctl net.ipv4.ip_forward
```

- Install containerd as per [containerd docs](https://github.com/containerd/containerd/blob/main/docs/getting-started.md#option-1-from-the-official-binaries)

```
# Modify for latest version
cd /tmp
sudo curl -L -O https://github.com/containerd/containerd/releases/download/v1.7.23/containerd-1.7.23-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-1.7.23-linux-amd64.tar.gz
sudo sudo rm containerd-1.7.23-linux-amd64.tar.gz
```

- Setup containerd to use systemd as per [containerd docs](https://github.com/containerd/containerd/blob/main/docs/getting-started.md#systemd)

```
sudo mkdir -p /usr/local/lib/systemd/system
sudo vim /usr/local/lib/systemd/system/containerd.service
# Paste in the contents of https://raw.githubusercontent.com/containerd/containerd/main/containerd.service

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
```

- Install runc as per [containerd docs](https://github.com/containerd/containerd/blob/main/docs/getting-started.md#step-2-installing-runc)

```
cd /tmp
sudo curl -L -O https://github.com/opencontainers/runc/releases/download/v1.2.0/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
sudo rm runc.amd64
```

- Install CNI plugins

```
sudo mkdir -p /opt/cni/bin
cd /tmp

sudo curl -L -O https://github.com/containernetworking/plugins/releases/download/v1.6.0/cni-plugins-linux-amd64-v1.6.0.tgz
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.6.0.tgz
sudo rm cni-plugins-linux-amd64-v1.6.0.tgz

sudo chown -R root:root /opt/cni/bin
```

- Configure containerd as per [k8s docs](https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd-systemd)

```
sudo mkdir -p /etc/containerd
sudo sh -c 'containerd config default > /etc/containerd/config.toml'
sudo vim /etc/containerd/config.toml
# edit all lines mentioning Systemd to true (just the one under runc)

sudo systemctl restart containerd
```

- Install kubelet kubeadm kubectl as per [kuberenetes documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl)

```
sudo apt-get update
# apt-transport-https may be a dummy package; if so, you can skip that package
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
# sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet
```

Next we gotta setup kube-vip (Only on control nodes!)

ARP

```
sudo -s

export VIP=10.69.60.10
export INTERFACE=enp2s0
export KVVERSION=v0.8.4

alias kube-vip="ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION; ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip"
kube-vip manifest pod \
    --interface $INTERFACE \
    --vip $VIP \
    --controlplane \
    --services \
    --arp \
    --leaderElection | tee /etc/kubernetes/manifests/kube-vip.yaml

exit

sudo vim /etc/kubernetes/manifests/kube-vip.yaml
# ONLY ON FIRST NODE due to issue 684 edit admin.conf to super-admin.conf, but just the bottom one https://github.com/kube-vip/kube-vip/issues/684
```

BGP

```
sudo -s

export VIP=10.69.60.10
export INTERFACE=lo
export KVVERSION=v0.8.4

alias kube-vip="ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION; ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip"

kube-vip manifest pod \
    --interface $INTERFACE \
    --address $VIP \
    --controlplane \
    --services \
    --bgp \
    --localAS 65000 \
    --bgpRouterID 10.69.60.11 \
    --peerAddress 10.69.60.1 \
    --peerAS 65100 | tee /etc/kubernetes/manifests/kube-vip.yaml

exit

sudo vim /etc/kubernetes/manifests/kube-vip.yaml
# ONLY ON FIRST NODE due to issue 684 edit admin.conf to super-admin.conf, but just the bottom one https://github.com/kube-vip/kube-vip/issues/684
```

Create the kuberenetes cluster
Run only on first control node

```
sudo kubeadm init --control-plane-endpoint "10.69.60.10:6443" --upload-certs
```

Now you must get cilium installed for the nodes to become ready

Move the admin.conf file to .kube/config

```
sudo mkdir /mnt/usb
sudo mount /dev/sdb2 /mnt/usb
sudo cp /etc/kubernetes/admin.conf /mnt/usb
sudo umount /mnt/usb

# on other machine
sudo mv admin.conf ~/.kube/conf
```

On you pc install the [celium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)

```
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

Install cilium

```
cilium install --version 1.16.3 --set kubeProxyReplacement=true --set ingressController.enabled=true --set ingressController.loadbalancerMode=dedicated --set ingressController.default=true
```

Join the server on the rest of the control nodes using the command provided by the kubeadm init

```
sudo kubeadm join 10.69.60.10:6443 --token fake.fake \
    --discovery-token-ca-cert-hash sha256:fake \
    --control-plane --certificate-key fake
```

Join the worker nodes using the command from kubeadm init

```
sudo kubeadm join 10.69.60.10:6443 --token fake.fake \
    --discovery-token-ca-cert-hash sha256:fake
```

HOLY FUCK DON'T FORGET TO CONFIGURE THE ON PREM CLOUD-CONTROLLER
https://kube-vip.io/docs/usage/cloud-provider/

IM TILTED
