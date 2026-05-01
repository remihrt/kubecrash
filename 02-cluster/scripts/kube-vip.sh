#!/bin/bash
# Generate the kube-vip static pod manifest.
# Run as root on each control plane node BEFORE kubeadm init/join.
#
# Usage: sudo INTERFACE=eth0 VIP=192.168.1.201 bash kube-vip.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

: "${INTERFACE:?Set INTERFACE to the node\'s primary network interface (find it with: ip -br link)}"
: "${VIP:=192.168.1.201}"

KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases/latest |
  grep '"tag_name"' | cut -d'"' -f4)

echo "Using kube-vip ${KVVERSION}, interface=${INTERFACE}, VIP=${VIP}"

mkdir -p /etc/kubernetes/manifests

ctr image pull "ghcr.io/kube-vip/kube-vip:${KVVERSION}"

ctr run --rm --net-host "ghcr.io/kube-vip/kube-vip:${KVVERSION}" vip \
  /kube-vip manifest pod \
  --interface "${INTERFACE}" \
  --address "${VIP}" \
  --controlplane \
  --arp \
  --leaderElection \
  >/etc/kubernetes/manifests/kube-vip.yaml

# kube-vip generates the manifest with admin.conf, but since Kubernetes 1.29
# admin.conf requires a RBAC binding that doesn't exist until after init completes.
# super-admin.conf has direct system:masters access and works immediately.
# Only patch the hostPath (source on the host), not the mountPath (path inside the container).
# kube-vip looks for the kubeconfig at /etc/kubernetes/admin.conf inside the container.
sed -i 's|path: /etc/kubernetes/admin.conf|path: /etc/kubernetes/super-admin.conf|g' \
  /etc/kubernetes/manifests/kube-vip.yaml

echo "Manifest written to /etc/kubernetes/manifests/kube-vip.yaml"
