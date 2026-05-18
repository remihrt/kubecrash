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

**Result**: zero errors. Pod rescheduled to `omarchbook` within seconds. Graceful eviction (SIGTERM + grace period) avoids the error spike seen with forced deletion. DaemonSet pods left in place. After uncordon, running pods don't migrate back — only new pods schedule on the restored node.

---

## Level 3 — Control plane chaos

### Kill one etcd member

```bash
# break
ssh homelab-1 "sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak"
# verify quorum holds
kubectl exec -n kube-system etcd-homelab-0 -- etcdctl \
  --endpoints=https://192.168.1.10:2379,https://192.168.1.11:2379,https://192.168.1.14:2379 \
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

**Note**: `sch_netem` is missing on Arch Linux nodes (`archbook`, `omarchbook`) — use a Debian node (`homelab-0` or `homelab-1`).

### Network partition

```bash
# isolate homelab-0 from the other two control planes
ssh homelab-0 "sudo iptables -I INPUT -s 192.168.1.11 -j DROP && \
  sudo iptables -I INPUT -s 192.168.1.14 -j DROP && \
  sudo iptables -I OUTPUT -d 192.168.1.11 -j DROP && \
  sudo iptables -I OUTPUT -d 192.168.1.14 -j DROP"

# heal
ssh homelab-0 "sudo iptables -D INPUT -s 192.168.1.11 -j DROP && \
  sudo iptables -D INPUT -s 192.168.1.14 -j DROP && \
  sudo iptables -D OUTPUT -d 192.168.1.11 -j DROP && \
  sudo iptables -D OUTPUT -d 192.168.1.14 -j DROP"
```

`homelab-0` held the VIP. Partition created a 1-vs-2 split.

**Result**: cluster survived. Majority side (`homelab-1` + `omarchbook`) kept Raft quorum and claimed the VIP. `homelab-0` etcd stalled (1/3, below quorum). On heal, `homelab-0` etcd replayed missed entries automatically.

---

## Level 5 — Storage & Data Recovery

### etcd snapshot + restore

Full disaster recovery: wipe all etcd data across every member and restore from a snapshot. This proves you can bring a cluster back from complete data loss.

The experiment has two scenarios back to back:

- **Scenario A** — restore recovers deleted resources (snapshot taken *before* deletion)
- **Scenario B** — restore discards rogue resources (snapshot taken *before* they were created)

Run Scenario A to learn the muscle memory, then Scenario B if you want to observe the inverse.

#### Step 1 — Take a snapshot

Run from the devcontainer. etcdctl runs inside the pod; save to `/var/lib/etcd/` which is bind-mounted so the file lands on the host filesystem at the same path.

```bash
kubectl exec -n kube-system etcd-homelab-0 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.db

# verify (snapshot status moved to etcdutl in etcd v3.6)
kubectl exec -n kube-system etcd-homelab-0 -- etcdutl \
  snapshot status /var/lib/etcd/snapshot.db -w table
```

Copy the snapshot to the devcontainer (scp works because `/var/lib/etcd` is on the host, not inside the container), then push to the other nodes' host:

```bash
ssh -t homelab-0 "sudo cp /var/lib/etcd/snapshot.db etcd-snapshot.db && sudo chown remi:remi etcd-snapshot.db" && \
scp homelab-0:~/etcd-snapshot.db . && \
scp etcd-snapshot.db homelab-1:~/ && \
scp etcd-snapshot.db omarchbook:~/
```

#### Step 2 — Create a canary resource (Scenario A)

Create something after the snapshot so you can prove it disappears on restore:

```bash
kubectl create configmap chaos-canary --from-literal=msg="this should vanish after restore"
kubectl get configmap chaos-canary
```

#### Step 3 — Stop etcd and kube-apiserver on all members

Move static pod manifests away so kubelet tears down the containers. Do all three nodes before anything has time to react.

```bash
for node in homelab-0 homelab-1 omarchbook; do
  ssh -t $node "sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak && \
             sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak"
done
```

Wait ~10s, then confirm the processes are gone:

```bash
for node in homelab-0 homelab-1 omarchbook; do
  ssh -t $node "sudo crictl ps 2>/dev/null | grep -E 'etcd|apiserver' || echo '$node: clear'"
done
```

#### Step 4 — Wipe all etcd data

```bash
for node in homelab-0 homelab-1 omarchbook; do
  ssh -t $node "sudo rm -rf /var/lib/etcd"
done
```

There is no going back from this point without the snapshot.

#### Step 5 — Restore the snapshot on each member

Each member needs its own restore call with a unique `--name` and `--initial-advertise-peer-urls`. All three share the same `--initial-cluster` and a new `--initial-cluster-token` (different from the original forces a fresh cluster identity and prevents stale peers from interfering).

```bash
INITIAL_CLUSTER="homelab-0=https://192.168.1.10:2380,homelab-1=https://192.168.1.11:2380,omarchbook=https://192.168.1.14:2380"

ssh -t homelab-0 "sudo etcdutl snapshot restore etcd-snapshot.db \
  --name homelab-0 \
  --initial-cluster ${INITIAL_CLUSTER} \
  --initial-cluster-token etcd-cluster-restored \
  --initial-advertise-peer-urls https://192.168.1.10:2380 \
  --data-dir /var/lib/etcd"

ssh -t homelab-1 "sudo etcdutl snapshot restore etcd-snapshot.db \
  --name homelab-1 \
  --initial-cluster ${INITIAL_CLUSTER} \
  --initial-cluster-token etcd-cluster-restored \
  --initial-advertise-peer-urls https://192.168.1.11:2380 \
  --data-dir /var/lib/etcd"

ssh -t omarchbook "sudo etcdutl snapshot restore etcd-snapshot.db \
  --name omarchbook \
  --initial-cluster ${INITIAL_CLUSTER} \
  --initial-cluster-token etcd-cluster-restored \
  --initial-advertise-peer-urls https://192.168.1.14:2380 \
  --data-dir /var/lib/etcd"
```

#### Step 6 — Restart etcd and kube-apiserver

Put the manifests back. kubelet picks them up within a few seconds.

```bash
for node in homelab-0 homelab-1 omarchbook; do
  ssh -t $node "sudo mv /tmp/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml && \
             sudo mv /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml"
done
```

#### Step 7 — Verify recovery

```bash
# wait for apiserver to accept requests (~30s)
while ! kubectl get nodes &>/dev/null; do echo "waiting..."; sleep 3; done

kubectl get nodes
kubectl get pods -A | grep -v Running  # any crashlooping?

# Scenario A: canary should be GONE (created after the snapshot)
kubectl get configmap chaos-canary && echo "UNEXPECTED: canary survived" || echo "OK: canary gone, restore worked"

# etcd cluster health
kubectl exec -n kube-system etcd-homelab-0 -- etcdctl \
  --endpoints=https://192.168.1.10:2379,https://192.168.1.11:2379,https://192.168.1.14:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health -w table
```

**Expected result**: all nodes Ready, etcd cluster healthy, canary ConfigMap absent.

---

### Disk pressure eviction

Trigger the kubelet's disk eviction manager by filling a node's filesystem past the hard eviction threshold (`nodefs.available < 10%`). Watch the kubelet set `DiskPressure`, taint the node, and evict pods by QoS class.

Target: `archbook` (worker node, 32G disk, 8.6G free at 71% — needs ~6G filled to cross 90%).

#### Step 1 — Baseline

```bash
# current disk state
ssh archbook "df -h /"

# current node conditions
kubectl describe node archbook | grep -A 10 Conditions:

# pods running on archbook
kubectl get pods -A -o wide | grep archbook
```

#### Step 2 — Fill the disk

```bash
ssh archbook "fallocate -l 6G /tmp/bigfile"
```

`fallocate` allocates blocks instantly without writing data — much faster than `dd`. If the threshold isn't crossed, increase to 7G or 8G.

#### Step 3 — Watch the kubelet react

Run these in separate terminals:

```bash
# watch node conditions flip to DiskPressure=True
kubectl get nodes -w

# watch pods being evicted
kubectl get pods -A -o wide -w

# watch eviction events
kubectl get events -A --field-selector reason=Evicting -w
```

The kubelet checks disk every 10s (housekeeping interval). Expect `DiskPressure=True` within ~30s and the node tainted with `node.kubernetes.io/disk-pressure:NoSchedule`.

Eviction order follows QoS class:
1. **BestEffort** — no requests/limits set
2. **Burstable** — requests set but below limits
3. **Guaranteed** — requests equal limits (evicted last)

#### Step 4 — Inspect the evicted state

```bash
# confirm DiskPressure condition and taint
kubectl describe node archbook | grep -E "DiskPressure|disk-pressure"

# see where evicted pods rescheduled
kubectl get pods -A -o wide | grep -v archbook
```

#### Step 5 — Recover

```bash
ssh archbook "rm /tmp/bigfile"
```

The kubelet detects the freed space within one housekeeping interval (~10s), removes the `DiskPressure` condition and the taint. No manual uncordon needed — the node becomes schedulable again automatically.

```bash
kubectl get nodes -w  # watch Ready condition return
```

**Expected result**: `DiskPressure` clears, taint removed, node schedulable again. Previously evicted pods may or may not migrate back depending on scheduler decisions.

---

## Level 6 — TLS & Certificates

### Certificate expiry + rotation

The experiment focuses on the renewal workflow. Manually crafting expired certs with openssl is unreliable — kubeadm reads extensions from the existing cert file when renewing, so a hand-rolled cert missing `ExtendedKeyUsage` will break `kubeadm certs renew`. Instead, learn what an expired cert failure looks like, then practice the real recovery tool.

#### What an expired apiserver-kubelet-client cert looks like

`apiserver-kubelet-client` is the cert the apiserver presents to kubelets when proxying `kubectl logs` and `kubectl exec`. When it expires:

- `kubectl get nodes` / `kubectl get pods` — still works (apiserver↔etcd path unaffected)
- `kubectl logs` / `kubectl exec` — fails with a misleading error:
  ```
  error: You must be logged in to the server (the server has asked for the client to provide credentials)
  ```
  This is actually the kubelet returning 401 to the apiserver because it rejected the expired cert. The apiserver forwards it verbatim to kubectl.

In an HA cluster the failure only appears on the specific node whose cert is expired. Routing through the VIP may hide it — connect directly to observe it:

```bash
kubectl --server=https://192.168.1.10:6443 logs -n podinfo deployment/podinfo  # fails
kubectl logs -n podinfo deployment/podinfo                                       # works (VIP → other node)
```

#### Step 1 — Inspect current cert expiry

```bash
for cert in apiserver apiserver-kubelet-client apiserver-etcd-client front-proxy-client; do
  echo "=== $cert ==="
  ssh homelab-0 "openssl x509 -in /etc/kubernetes/pki/${cert}.crt -noout -dates"
done
```

CA cert: 10-year validity. Component certs: 1 year, issued by kubeadm at cluster init.

#### Step 2 — Renew all certs on every control plane node

Run on each node. `kubeadm certs renew all` reissues every component cert signed by the existing CA — no CA rotation, no downtime at this step:

```bash
for node in homelab-0 homelab-1 omarchbook; do
  ssh -t $node "sudo kubeadm certs renew all"
done
```

Verify new expiry dates on one node:

```bash
ssh homelab-0 "openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates"
```

#### Step 3 — Restart control plane components to load new certs

Kubeadm writes new cert files but running components hold the old certs in memory. Each component must be restarted. Do one node at a time to keep the cluster available during rotation.

```bash
for node in homelab-0 homelab-1 omarchbook; do
  ssh $node "for f in /etc/kubernetes/manifests/*.yaml; do \
    sudo mv \$f /tmp/ && sleep 5 && sudo mv /tmp/\$(basename \$f) /etc/kubernetes/manifests/; \
  done"
done
```

Wait for all components to recover between nodes:

```bash
kubectl get pods -n kube-system -w
```

#### Step 4 — Verify

```bash
# all components running
kubectl get pods -n kube-system

# logs and exec work on every node directly
kubectl --server=https://192.168.1.10:6443 logs -n podinfo deployment/podinfo
kubectl --server=https://192.168.1.11:6443 logs -n podinfo deployment/podinfo
kubectl --server=https://192.168.1.14:6443 logs -n podinfo deployment/podinfo
```

**Expected result**: all certs show a new `notAfter` ~1 year out, all commands succeed on every node directly.
