# Postmortem — Scheduler Stuck After etcd Restore

**Date:** 2026-05-05
**Severity:** Cluster degraded — new pods not scheduled
**Duration:** ~5 minutes (detected and resolved during chaos experiment)

---

## Summary

After a full etcd disaster recovery (all members wiped, snapshot restored), newly created pods hung in Pending indefinitely. The kube-scheduler was Running and held the leader lease but was silently not scheduling anything. Root cause: transient RBAC errors during apiserver startup corrupted the scheduler's informer initialization, leaving it with no working watches.

---

## Timeline

| Time | Event |
|------|-------|
| 15:16 | etcd and kube-apiserver manifests restored on all 3 nodes |
| 15:17:13 | Scheduler logs show burst of `is forbidden` errors while apiserver cache loads |
| 15:17:32 | Scheduler acquires leader lease (`homelab-0`) |
| 15:17:43 | Scheduler informer caches report synced (macmini instance) |
| 15:35 | New pods created — all stuck Pending |
| 15:37 | No FailedScheduling events observed — identified as scheduler issue |
| 15:38 | Scheduler pods restarted on all nodes |
| 15:38 | Pods scheduled within seconds |

---

## Root Cause

The kube-apiserver starts before its RBAC cache is fully loaded. During that window (~15 seconds), the scheduler's informers attempt to establish watches and receive `403 Forbidden` responses for resources like `nodes`, `services`, `persistentvolumes`.

The informers interpret these as fatal initialization errors and stop retrying. The scheduler then acquires the leader lease and enters its scheduling loop — but its informers are dead. It cannot see nodes or pending pods. It schedules nothing and logs nothing.

RBAC itself was not broken: `kubectl auth can-i list nodes --as=system:kube-scheduler` confirmed the ClusterRoleBinding was intact. The forbidden errors were a timing artifact, not a real permission issue.

---

## Debugging Process

**Step 1 — Check if the scheduler has tried**

```bash
kubectl get events -A --field-selector reason=FailedScheduling
```

No events. The scheduler has not attempted scheduling. This rules out placement constraints (taints, affinity, insufficient resources) — those would produce FailedScheduling events. The problem is in the scheduler itself.

**Step 2 — Check node health**

```bash
kubectl describe node archbook | grep -A10 Conditions:
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'
```

All nodes Ready, no taints, no pressure conditions. Not a node-side issue.

**Step 3 — Check scheduler pods and leader**

```bash
kubectl get pods -n kube-system | grep scheduler
kubectl get lease kube-scheduler -n kube-system -o jsonpath='{.spec.holderIdentity}'
```

All scheduler pods Running. `homelab-0` holds the leader lease. The scheduler is alive and elected.

**Step 4 — Read scheduler logs**

```bash
kubectl logs -n kube-system kube-scheduler-homelab-0 --tail=20
```

Two signals:
- Burst of `is forbidden` errors at 15:17:13 (during apiserver startup)
- `Successfully acquired lease` at 15:17:32
- Nothing after that — no scheduling activity

**Step 5 — Verify RBAC is not actually broken**

```bash
kubectl auth can-i list nodes --as=system:kube-scheduler
# → yes
```

RBAC is intact. The forbidden errors were transient. The scheduler's informers just never recovered from them.

---

## Resolution

Restart all scheduler pods to reinitialize informers cleanly:

```bash
for node in homelab-0 homelab-1 macmini; do
  ssh $node "sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/ && \
             sleep 2 && \
             sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/"
done
```

---

## Lessons Learned

- **No FailedScheduling events = scheduler problem, not placement problem.** FailedScheduling events are only emitted when the scheduler actively attempts and fails. Silence means it hasn't tried.
- **The scheduler can hold the leader lease and still be non-functional.** Lease acquisition and informer health are independent. Always check logs for scheduling activity, not just pod status.
- **Transient RBAC errors during apiserver startup can permanently break informers.** The scheduler does not retry failed informer initialization. A restart is required.
- **After any control plane restart, verify scheduling works** by checking that existing pending pods get assigned nodes within ~30 seconds.
