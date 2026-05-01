# Cluster Bootstrap

Bootstrap a 4-node HA Kubernetes cluster using kubeadm.

## Architecture

- **Container runtime**: containerd
- **HA control plane**: kube-vip (ARP mode) — VIP `192.168.1.201`
- **CNI**: Cilium

## Topology

| Node | IP | Interface | Role |
|---|---|---|---|
| archbook | 192.168.1.12 | `wlan0` | control-plane + worker *(init here first)* |
| homelab-0 | 192.168.1.10 | `wlan0` | control-plane + worker |
| homelab-1 | 192.168.1.11 | `wlan0` | control-plane + worker |
| macmini | 192.168.1.13 | `end0` | worker |

All nodes are on WiFi except macmini which is on Ethernet. kube-vip needs the correct interface per node.

kube-vip provides a virtual IP (`192.168.1.201`) that floats across the 3 control plane nodes. Losing one control plane keeps the cluster running — etcd maintains quorum with 2 of 3.

---

## Step 0 — Disable Docker on archbook

archbook has Docker installed and running. Its iptables rules conflict with Cilium. Disable it before bootstrapping:

```bash
sudo systemctl disable --now docker
```

---

## Step 1 — Node setup (all nodes)

Copy and run as root on every node:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/.../scripts/node-setup.sh)
```

Or copy the script over and run it:

```bash
scp scripts/node-setup.sh remi@<node>:~
ssh remi@<node> "sudo bash node-setup.sh"
```

This installs containerd, kubeadm, kubelet, and kubectl, and configures the required kernel modules and sysctl settings. It handles Debian, Arch Linux, and Fedora automatically.

---

## Step 2 — kube-vip (control plane nodes only)

Run as root on **archbook**, **homelab-0**, and **homelab-1** with the correct interface per node:

```bash
# archbook
INTERFACE=wlan0 VIP=192.168.1.201 sudo -E bash scripts/kube-vip.sh

# homelab-0
INTERFACE=wlan0 VIP=192.168.1.201 sudo -E bash scripts/kube-vip.sh

# homelab-1
INTERFACE=wlan0 VIP=192.168.1.201 sudo -E bash scripts/kube-vip.sh
```

kube-vip runs as a static pod, so the manifest must exist in `/etc/kubernetes/manifests/` before `kubeadm init` or `kubeadm join`.

---

## Step 3 — Initialize the cluster (archbook only)

Open **two terminals** on archbook for this step.

**Terminal 1** — start the init:
```bash
sudo kubeadm init --config kubeadm-config.yaml --upload-certs
```

**Terminal 2** — as soon as you see `kube-apiserver is healthy`, apply the kube-vip RBAC:
```bash
sudo KUBECONFIG=/etc/kubernetes/super-admin.conf kubectl apply -f https://kube-vip.io/manifests/rbac.yaml --server=https://192.168.1.12:6443
```

kube-vip needs this to win leader election and claim the VIP (`192.168.1.201`). Without it kubeadm will time out at the `upload-config` phase trying to reach the VIP.

> Use `super-admin.conf`, not `admin.conf`. Since Kubernetes 1.29, `admin.conf` gets cluster-admin access via a RBAC binding that doesn't exist until init completes. `super-admin.conf` retains direct `system:masters` membership and works immediately.

Once init completes, copy the kubeconfig:
```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Also copy it to the devcontainer's `.kube/` so kubectl works from there:
```bash
scp remi@192.168.1.12:~/.kube/config /path/to/kubecrash/.kube/config
```

**Save the full kubeadm output** — it contains the join commands for both control plane and worker nodes. They expire after 24 hours.

---

## Step 5 — Install Cilium (from archbook)

```bash
CILIUM_CLI_VERSION=$(curl -sL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvf cilium-linux-amd64.tar.gz --directory /usr/local/bin cilium
rm cilium-linux-amd64.tar.gz

cilium install
cilium status --wait
```

Nodes will move to `Ready` once Cilium is running.

---

## Step 6 — Join control plane nodes (homelab-0, homelab-1)

Do this for each node **one at a time**. Complete all sub-steps on one node before starting the next.

**1. Generate a fresh join command** (from the devcontainer or archbook — certificate keys expire after 2 hours):
```bash
sudo kubeadm init phase upload-certs --upload-certs  # prints a new --certificate-key
kubeadm token create --print-join-command        # prints token and CA hash
```
Combine both outputs into:
```
sudo kubeadm join 192.168.1.201:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key>
```

**2. Generate the kube-vip manifest** on the joining node (must exist before kubeadm join):
```bash
scp scripts/kube-vip.sh remi@homelab-0:~
ssh homelab-0
sudo INTERFACE=wlan0 VIP=192.168.1.201 bash kube-vip.sh
```

**3. Run the join command** on the node as root:
```bash
sudo kubeadm join 192.168.1.201:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key>
```

**4. Copy the kubeconfig** on the node:
```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Repeat for homelab-1.

---

## Step 7 — Join worker node (macmini)

**1. Generate a fresh join command** (from the devcontainer or archbook):
```bash
kubeadm token create --print-join-command
```

**2. Run it on macmini** as root:
```bash
sudo kubeadm join 192.168.1.201:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Step 8 — Untaint control planes

By default kubeadm prevents workloads from scheduling on control plane nodes. Remove the taint:

```bash
kubectl taint nodes archbook homelab-0 homelab-1 node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Verify

```bash
kubectl get nodes -o wide
cilium status
```

All 4 nodes should be `Ready`. The control plane nodes will show both `control-plane` and `worker` roles.
