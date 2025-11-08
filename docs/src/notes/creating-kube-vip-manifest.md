```
sudo -s

export VIP=10.69.60.10
export INTERFACE=lo
export KVVERSION=v1.0.1

# export KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")

alias kube-vip="ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION; ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip"

kube-vip manifest daemonset \
--interface $INTERFACE \
--address $VIP \
--inCluster \
--taint \
--controlplane \
--services \
--bgp \
--localAS 65000 \
--bgpRouterID 10.69.60.11 \
--peerAddress 10.69.60.1 \
--peerAS 65100 | tee ./manifest.yaml

exit
```
