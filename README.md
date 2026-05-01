# kubecrash

A hands-on Kubernetes mastery project. Build a real cluster on physical machines, break it intentionally, and learn Kubernetes deeply by operating and recovering from failures.

No managed Kubernetes. No shortcuts. Just nodes, `kubeadm`, and chaos.

## Cluster

4-node cluster with a high-availability control plane. All nodes are schedulable.

| Hostname | IP | Hardware | OS | Role |
|---|---|---|---|---|
| archbook | 192.168.1.12 | MacBook Pro 2013 — Intel, 16 GB RAM, 512 GB SSD | Arch Linux | control-plane + worker |
| homelab-0 | 192.168.1.10 | Raspberry Pi 5 — arm64, 4 GB RAM, 32 GB USB | Debian 13 (trixie) | control-plane + worker |
| homelab-1 | 192.168.1.11 | Raspberry Pi 5 — arm64, 4 GB RAM, 32 GB USB | Debian 13 (trixie) | control-plane + worker |
| macmini | 192.168.1.13 | Mac Mini M1 — Apple Silicon, 8 GB RAM, 128 GB SSD | Fedora Asahi Remix 43 | worker |

3 control plane nodes form an etcd quorum — losing one node keeps the cluster alive. The mixed architectures (x86_64, arm64, aarch64) make multi-arch container images a real concern, not a theoretical one.

## Structure

```
01-setup/     Raspberry Pi OS flashing and configuration
02-cluster/   kubeadm bootstrap and cluster configuration
  ├── README.md              Step-by-step bootstrap guide
  ├── kubeadm-config.yaml   Cluster configuration (VIP, pod CIDR)
  └── scripts/
      ├── node-setup.sh     Prerequisites for all nodes (multi-distro)
      └── kube-vip.sh       kube-vip static pod manifest generator
```

## Philosophy

The goal is not a working cluster — it's understanding what breaks and why. Expect things to be intentionally destroyed:

- Control plane node failures and etcd quorum loss
- Network partitions and split-brain scenarios
- etcd corruption and restoration from backup
- Pod eviction storms and resource exhaustion
- Certificate expiry and rotation

## Development Environment

The repo includes a VS Code devcontainer (Ubuntu 24.04) with `kubectl` and `claude-code` managed via `mise`. The devcontainer runs with `--network=host` so it can reach cluster nodes directly.

The kubeconfig lives outside the repo at `~/.kube/` (host-mounted into the container, gitignored).
