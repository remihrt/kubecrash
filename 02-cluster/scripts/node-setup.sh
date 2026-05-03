#!/bin/bash
# Run as root on every node before kubeadm init/join.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

. /etc/os-release

# ── /etc/hosts ───────────────────────────────────────────────────────────────
if ! grep -q 'homelab-0' /etc/hosts; then
  cat >> /etc/hosts << 'EOF'

# kubecrash cluster nodes
192.168.1.10  homelab-0
192.168.1.11  homelab-1
192.168.1.12  archbook
192.168.1.13  macmini
EOF
fi

# ── Swap ─────────────────────────────────────────────────────────────────────
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab
# Disable Raspberry Pi OS zram swap (managed via rpi config, not fstab)
if [[ -d /etc/rpi ]]; then
  mkdir -p /etc/rpi/swap.conf.d
  echo -e '[Main]\nMechanism=none' > /etc/rpi/swap.conf.d/90-disable-swap.conf
  swapoff /dev/zram0 2>/dev/null || true
fi

# ── Kernel modules ────────────────────────────────────────────────────────────
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ── Sysctl ────────────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ── containerd ────────────────────────────────────────────────────────────────
configure_containerd() {
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  # Required for systemd cgroup driver — must match kubelet
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  systemctl restart containerd
}

# ── Distro-specific install ───────────────────────────────────────────────────
enable_rpi_cgroups() {
  # Raspberry Pi OS disables memory cgroup by default — required by kubelet
  CMDLINE=/boot/firmware/cmdline.txt
  if [[ -f "$CMDLINE" ]] && ! grep -q 'cgroup_enable=memory' "$CMDLINE"; then
    sed -i '$ s/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"
    echo "Memory cgroup enabled — reboot required before running kubeadm join"
  fi
}

install_debian() {
  K8S_MINOR=$(curl -sL https://dl.k8s.io/release/stable.txt | grep -oP 'v\K[0-9]+\.[0-9]+')

  apt-get update -q
  apt-get install -y apt-transport-https ca-certificates curl gpg containerd
  configure_containerd

  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -q
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl

  # kubelet expects CNI plugins in /usr/lib/cni/ but Cilium installs to /opt/cni/bin/
  mkdir -p /usr/lib/cni
  ln -sf /opt/cni/bin/cilium-cni /usr/lib/cni/cilium-cni
  ln -sf /opt/cni/bin/loopback   /usr/lib/cni/loopback
}

install_arch() {
  ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
  K8S_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)

  pacman -Sy --noconfirm containerd
  configure_containerd

  # Binaries from official Kubernetes releases — kubeadm/kubelet not in official Arch repos
  for bin in kubeadm kubelet kubectl; do
    curl -sLO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/${bin}"
    install -o root -g root -m 0755 "${bin}" /usr/local/bin/"${bin}"
    rm "${bin}"
  done

  # kubelet systemd unit from the kubernetes/release repo
  RELEASE_TAG=$(curl -sL https://api.github.com/repos/kubernetes/release/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
  BASE="https://raw.githubusercontent.com/kubernetes/release/${RELEASE_TAG}/cmd/krel/templates/latest"
  curl -sL "${BASE}/kubelet/kubelet.service" \
    | sed 's:/usr/bin:/usr/local/bin:g' > /etc/systemd/system/kubelet.service
  mkdir -p /etc/systemd/system/kubelet.service.d
  curl -sL "${BASE}/kubeadm/10-kubeadm.conf" \
    | sed 's:/usr/bin:/usr/local/bin:g' > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
  systemctl daemon-reload
  systemctl enable kubelet
}

install_fedora() {
  K8S_MINOR=$(curl -sL https://dl.k8s.io/release/stable.txt | grep -oP 'v\K[0-9]+\.[0-9]+')

  # SELinux in enforcing mode conflicts with containerd in a homelab setup
  setenforce 0 || true
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

  systemctl disable --now firewalld || true

  dnf install -y containerd
  configure_containerd

  cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
EOF

  dnf install -y kubelet kubeadm kubectl
  systemctl enable kubelet
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$ID" in
  debian)              enable_rpi_cgroups; install_debian ;;
  arch)                install_arch ;;
  fedora|fedora-asahi-remix) install_fedora ;;
  *)
    echo "Unsupported distro: $ID" >&2
    exit 1
    ;;
esac

echo "Node setup complete on $(hostname). Ready for kubeadm."
