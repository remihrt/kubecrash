# Postmortem — Disk Pressure Eviction

**Date:** 2026-05-06
**Severity:** Node degraded — pods evicted, replacements pending
**Duration:** ~30 minutes (intentional chaos experiment)

---

## Summary

Disk pressure was induced on `archbook` (the only worker node) by writing a large file to its filesystem. The kubelet set `DiskPressure=True` and applied a `NoSchedule` taint, but existing pods were not evicted until the file was enlarged past the hard eviction threshold. Once evicted, replacement pods could not start on other nodes due to a kubelet watch regression from the previous etcd restore experiment. Recovery required restarting the kubelets on the control plane nodes.

---

## Timeline

| Time | Event |
|------|-------|
| T+0 | `fallocate -l 6G /tmp/bigfile` on archbook |
| T+30s | `DiskPressure=True` condition set, `node.kubernetes.io/disk-pressure:NoSchedule` taint applied |
| T+1m | Existing pods remain running — no eviction observed |
| T+5m | Bigfile enlarged further, hard eviction threshold crossed |
| T+6m | Kubelet evicts pods: `Evicted`, `ContainerStatusUnknown`, `Error` statuses appear |
| T+7m | Replacement pods created by ReplicaSets, stuck Pending on homelab-0/1 and macmini |
| T+20m | Identified kubelet watch regression — kubelets restarted on control plane nodes |
| T+21m | Replacement pods start running |
| T+25m | `rm /tmp/bigfile` on archbook |
| T+30m | `DiskPressure` condition clears, taint removed automatically |

---

## Root Cause

### Primary: disk pressure threshold not crossed initially

The initial `fallocate -l 6G` brought archbook to ~90% disk usage, triggering the `DiskPressure` condition and `NoSchedule` taint. However, `NoSchedule` only blocks *new* scheduling — it has no effect on pods already running. Eviction is a separate kubelet mechanism, triggered only when the hard eviction threshold (`nodefs.available < 10%`) is crossed. The file was not large enough to cross it on the first attempt.

### Secondary: kubelet watch regression from etcd restore

After eviction, replacement pods were bound to control plane nodes by the scheduler (NODE column populated) but never started — no image pull events, no errors. Root cause: the kubelets on homelab-0, homelab-1, and macmini had a dead pod watch from the previous etcd restore experiment. The kubelet sends node heartbeats on a separate path (node shows Ready), but its pod assignment watch had silently failed, so it never saw the new pod bindings.

---

## Key Distinctions Learned

### NoSchedule taint ≠ eviction

| Mechanism | Trigger | Effect on existing pods | Effect on new pods |
|-----------|---------|-------------------------|--------------------|
| `NoSchedule` taint | `DiskPressure=True` | None — pods keep running | Blocked from scheduling |
| Kubelet eviction | Hard threshold crossed (`nodefs.available < 10%`) | Evicted in QoS order | N/A |

### Pod statuses after eviction

| Status | Cause |
|--------|-------|
| `Evicted` | Kubelet eviction manager removed the pod due to disk pressure |
| `ContainerStatusUnknown` | Kubelet lost track of container state — happened here due to the etcd restore disruption from the previous day |
| `Error` | Container exited non-zero |

All three are terminal — ReplicaSets create replacements automatically. Clean up with:
```bash
kubectl delete pods -A --field-selector=status.phase=Failed
```

### DiskPressure recovery

The kubelet clears `DiskPressure` and removes the taint automatically once disk usage drops below the threshold. It re-evaluates on its housekeeping interval (~10s) but the condition update can lag by 30–60s. No manual intervention needed.

---

## Debugging Process

**Step 1 — Pods not evicted after taint**

```bash
kubectl describe node archbook | grep -A10 Conditions:
kubectl get pods -A -o wide | grep archbook
```

Node had `DiskPressure=True` and `NoSchedule` taint, but pods were still running. Identified the distinction: `NoSchedule` ≠ eviction. Enlarged the bigfile to push past the 10% available threshold.

**Step 2 — Replacement pods Pending with no FailedScheduling events**

```bash
kubectl get events -A --field-selector reason=FailedScheduling
kubectl get pods -A --field-selector=status.phase=Pending -o wide
```

No FailedScheduling events, but pods had a NODE assigned. Scheduler had bound them — kubelet was not starting them. Same diagnostic signal as the scheduler postmortem: silence means the component hasn't tried, not that it tried and failed.

**Step 3 — Kubelet logs show no activity on target pods**

```bash
ssh macmini "journalctl -u kubelet --since '5 minutes ago' | grep -v 'kube-scheduler-macmini' | grep -iE 'error|warn|fail'"
```

Only noise from the etcd restore (stale static pod UID). No errors about nginx or podinfo pods — kubelet wasn't seeing them at all. Watch was dead.

**Fix:** restart kubelets on all affected nodes:

```bash
for node in homelab-0 homelab-1 macmini; do
  ssh -t $node "sudo systemctl restart kubelet"
done
```

---

## Lessons Learned

- **`NoSchedule` blocks new scheduling only.** Eviction requires the kubelet's eviction manager to cross a threshold — it is entirely separate from taints.
- **Eviction order follows QoS class:** BestEffort → Burstable → Guaranteed. DaemonSet pods tolerate the `disk-pressure` taint and are not evicted.
- **A node showing Ready does not mean its pod watch is healthy.** Heartbeat and pod watch are independent kubelet subsystems. After a control plane disruption, always verify that pods actually start, not just that nodes are Ready.
- **The etcd restore left a latent kubelet watch regression** that only manifested when new pods needed to be scheduled to those nodes. Control plane chaos can have delayed side effects on worker-side components.
- **`ContainerStatusUnknown` is a sign of kubelet/runtime state loss**, not a transient error — pods in this state will never recover on their own and should be deleted.
