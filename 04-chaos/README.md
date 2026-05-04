# Chaos Testing

Load: Locust at 50 users (~25–50 RPS) against podinfo (4 replicas). API health monitored with:

```bash
while true; do curl -sk https://192.168.1.201:6443/healthz && echo " OK $(date +%T)" || echo " FAIL $(date +%T)"; sleep 1; done
```

---

## Level 1 — Pod chaos

### Partial pod deletion

```bash
kubectl delete pod <one-pod> -n podinfo
```

**Result**: zero errors. Cilium removes the pod from Service endpoints before it dies — remaining 3 pods absorb all traffic transparently.

### Full pod deletion

```bash
kubectl delete pods -n podinfo --all
```

**Result**: ~1% error rate for a few seconds. New pods are created immediately but take time to pass readiness checks — brief window with no healthy backends.

**Fix**: a `PodDisruptionBudget` with `minAvailable: 2` blocks simultaneous eviction.

### OOM kill

```bash
kubectl exec -n podinfo <pod> -- sh -c "x=\$(head -c 128m /dev/zero)"
```

podinfo memory limit: 64Mi. Allocating 128Mi triggers the kernel OOM killer.

**Result**: `lastState.terminated.reason: OOMKilled`, `restarts: 1`. Pod back running in ~2s.

**Note**: `> /dev/null` does not work — data must accumulate in memory (shell variable or `/dev/shm`).

---

## Level 2 — Node eviction

### Drain the worker node

```bash
kubectl drain archbook --ignore-daemonsets --delete-emptydir-data
# watch pods reschedule
kubectl get pods -n podinfo -o wide -w
# restore
kubectl uncordon archbook
```

**Result**: zero errors. Pod rescheduled to `macmini` within seconds. Graceful eviction (SIGTERM + grace period) avoids the error spike seen with forced deletion. DaemonSet pods left in place. After uncordon, running pods don't migrate back — only new pods schedule on the restored node.

---

## Level 3 — Control plane chaos

### Kill one etcd member

```bash
# break
ssh homelab-1 "sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak"
# verify quorum holds
kubectl exec -n kube-system etcd-homelab-0 -- etcdctl \
  --endpoints=https://192.168.1.10:2379,https://192.168.1.11:2379,https://192.168.1.13:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health -w table
# restore
ssh homelab-1 "sudo mv /tmp/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml"
```

**Result**: cluster unaffected. Majority (2/3) maintained Raft quorum. Member resynced automatically on return.

### Power off a control plane (VIP holder)

```bash
ssh homelab-0 "sudo poweroff"
```

`homelab-0` held the kube-vip VIP (`192.168.1.201`) at the time.

**Timeline**:
```
14:08:14 — last OK
14:08:15–14:08:41 — silent gap (curl blocked on stale ARP cache)
14:08:42 — 1× FAIL
14:08:43 — OK (VIP now on homelab-1)
```

**Total downtime**: ~28s | **Visible failures**: 1

The long silent gap is stale ARP — curl was connecting to `homelab-0`'s MAC which no longer responded. kube-vip on `homelab-1` won the election at `14:08:38` and sent a gratuitous ARP to claim the VIP.

### Kill kube-apiserver (VIP holder)

```bash
# break
ssh homelab-1 "sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak"
# restore
ssh homelab-1 "sudo mv /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml"
```

`homelab-1` held the VIP at the time.

**Timeline**:
```
14:14:19 — last OK
14:14:20–14:14:31 — 12× FAIL (connection refused, instant)
14:14:32–14:14:38 — silent gap (kube-vip ARP failover)
14:14:39 — OK (VIP now on homelab-0)
```

**Total downtime**: ~19s | **Visible failures**: 12

Faster than the power-off because the network stayed alive — ARP propagated instantly once kube-vip won the election. More visible failures because connection refused returns immediately instead of blocking.

kube-vip lost the VIP because it uses a Kubernetes Lease for leader election and couldn't renew it without a local apiserver.

---

## Level 4 — Network chaos

### Inject latency

```bash
# inject (on a Debian/Fedora node — sch_netem missing on Arch Linux)
ssh homelab-1 "sudo modprobe sch_netem && sudo tc qdisc add dev wlan0 root netem delay 200ms"
# verify
ssh homelab-1 "sudo tc qdisc show dev wlan0"
# remove
ssh homelab-1 "sudo tc qdisc del dev wlan0 root"
```

`homelab-1` was the etcd leader at the time. Each write requires leader→follower replication through the degraded link: ~400ms added per etcd commit (200ms each direction). `kubectl` commands noticeably slower, Locust p99 latency climbed.

**Note**: `sch_netem` is missing on `archbook` (Arch Linux 7.0.2) — use a Debian or Fedora node.

### Network partition

```bash
# isolate homelab-0 from the other two control planes
ssh homelab-0 "sudo iptables -I INPUT -s 192.168.1.11 -j DROP && \
  sudo iptables -I INPUT -s 192.168.1.13 -j DROP && \
  sudo iptables -I OUTPUT -d 192.168.1.11 -j DROP && \
  sudo iptables -I OUTPUT -d 192.168.1.13 -j DROP"

# heal
ssh homelab-0 "sudo iptables -D INPUT -s 192.168.1.11 -j DROP && \
  sudo iptables -D INPUT -s 192.168.1.13 -j DROP && \
  sudo iptables -D OUTPUT -d 192.168.1.11 -j DROP && \
  sudo iptables -D OUTPUT -d 192.168.1.13 -j DROP"
```

`homelab-0` held the VIP. Partition created a 1-vs-2 split.

**Result**: cluster survived. Majority side (`homelab-1` + `macmini`) kept Raft quorum and claimed the VIP. `homelab-0` etcd stalled (1/3, below quorum). On heal, `homelab-0` etcd replayed missed entries automatically.
