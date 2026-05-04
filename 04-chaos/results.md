# Chaos Results

## Session 1 — 2026-05-04

Load: Locust at 50 users (~25–50 RPS) against podinfo (4 replicas). Monitoring via Prometheus + Grafana.

### Level 1 — Pod chaos

**Partial pod deletion** (1 of 4 replicas)
- Result: zero errors
- Cilium removes the pod from Service endpoints before it dies — remaining 3 pods absorb all traffic transparently

**Full pod deletion** (all 4 replicas at once)
- Result: ~1% error rate for a few seconds
- New pods are created immediately but take time to pass readiness checks — brief window with no healthy backends
- Fix: a PodDisruptionBudget with `minAvailable: 2` would block simultaneous eviction

**OOM kill**
- Allocated 128Mi in a pod with a 64Mi limit via shell variable (`x=$(head -c 128m /dev/zero)`)
- Kernel OOM-killed the container: `lastState.terminated.reason: OOMKilled`, `restarts: 1`
- Pod back running in ~2s
- Note: `> /dev/null` doesn't work — data must accumulate in memory (shell variable or `/dev/shm`)

### Level 2 — Node eviction

**Drain `archbook`** (only worker)
- Result: zero errors, pod rescheduled to `macmini` within seconds
- Graceful eviction (SIGTERM + grace period) vs forced deletion explains the zero errors vs 1% above
- DaemonSet pods left in place (`--ignore-daemonsets`)
- After uncordon: `archbook` rejoined immediately, running pods didn't migrate back

### Level 3 — Control plane chaos

**Kill one etcd member** (`homelab-1`)
- Removed `/etc/kubernetes/manifests/etcd.yaml`
- Cluster unaffected: majority (2/3) maintained Raft quorum
- Member resynced automatically on return — no manual intervention

**Power off control plane** (`homelab-0`, VIP holder)
- Timeline: last OK `14:08:14` → silent gap (stale ARP) → 1× FAIL `14:08:42` → OK `14:08:43`
- Total downtime: ~28s | Visible failures: 1
- Long silent gap caused by stale ARP cache — curl blocked waiting for a dead NIC
- kube-vip won election at `14:08:38`, sent gratuitous ARP → traffic shifted to `homelab-1`

**Kill kube-apiserver** (`homelab-1`, VIP holder)
- Timeline: last OK `14:14:19` → 12× FAIL `14:14:20–14:14:31` → VIP migrates → OK `14:14:39`
- Total downtime: ~19s | Visible failures: 12
- Faster than power-off (network stayed alive → ARP propagated instantly)
- More visible failures (connection refused is instant, not a silent block)
- kube-vip lost the VIP because it couldn't renew its Kubernetes Lease without a local apiserver

### Level 4 — Network chaos

**Inject 200ms latency** (`homelab-1`, etcd leader at the time)
- `sudo tc qdisc add dev wlan0 root netem delay 200ms`
- Each etcd write: leader→follower replication through degraded link → ~400ms added per commit
- `kubectl` commands noticeably slower, Locust p99 latency climbed
- `sch_netem` module missing on `archbook` (Arch Linux 7.0.2) — use Debian/Fedora nodes

**Network partition** (`homelab-0` isolated from `homelab-1` + `macmini`)
- Used iptables DROP rules on `homelab-0` (VIP holder)
- Majority side kept quorum, claimed the VIP — cluster survived
- `homelab-0` etcd stalled (1/3, below quorum threshold)
- On heal: `homelab-0` etcd replayed missed entries automatically, no manual steps needed
