# I am just jogging down some notes of what I have done

- Wifi needs to be enabled in Dell BIOS
- Fresh install of Debian Bookworm. NO SWAP! No additional packages. Not even standard system utilities.
- The nic somehow just works perfect with no driver configuration
- Assigned static ip address in mikrotik
- install vim

```
sudo apt install vim
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
sysctl net.ipv4.ip_forward
```

- Install containerd as per [containerd docs](https://github.com/containerd/containerd/blob/main/docs/getting-started.md#option-1-from-the-official-binaries)

```
cd /usr/local
sudo curl -L -O https://github.com/containerd/containerd/releases/download/v1.6.35/containerd-1.6.35-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-1.6.35-linux-amd64.tar.gz
```

- Setup containerd to use systemd as per [containerd docs](https://github.com/containerd/containerd/blob/main/docs/getting-started.md#systemd)

```
sudo mkdir -p /usr/local/lib/systemd/system
sudo vim /usr/local/lib/systemd/system/containerd.service
# Paste in the contents of https://raw.githubusercontent.com/containerd/containerd/main/containerd.service

systemctl daemon-reload
systemctl enable --now containerd
```

- Install runc as per [containerd docs](https://github.com/containerd/containerd/blob/main/docs/getting-started.md#step-2-installing-runc)

```
sudo mkdir -p /usr/local/sbin/runc
cd /usr/local/sbin/runc
sudo curl -L -O https://github.com/opencontainers/runc/releases/download/v1.2.0-rc.2/runc.amd64
sudo chmod 755 runc.amd64
```

- Install CNI plugins

```
sudo mkdir -p /opt/cni/bin
cd /opt/cni/bin

sudo curl -L -O https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.5.1.tgz
```

- Configure containerd as per [k8s docs](https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd-systemd)

```
sudo sh -c 'containerd config default > /etc/containerd/config.toml'
sudo vim /etc/containerd/config.toml
# edit line 139 to true
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
