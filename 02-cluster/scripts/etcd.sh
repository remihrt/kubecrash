#!/usr/bin/env bash
# Helper to manage etcd via kubectl exec on an etcd pod.
# Usage: etcd.sh <command> [args...]
#   etcd.sh health          — check health of all members
#   etcd.sh members         — list all members
#   etcd.sh remove <id>     — remove a member by ID (hex)
#   etcd.sh add <name> <peer-url>  — add a new member

set -euo pipefail

NAMESPACE="kube-system"
ETCD_POD="${ETCD_POD:-$(kubectl get pods -n "$NAMESPACE" -l component=etcd -o jsonpath='{.items[0].metadata.name}')}"

ETCDCTL_FLAGS=(
  --cacert=/etc/kubernetes/pki/etcd/ca.crt
  --cert=/etc/kubernetes/pki/etcd/server.crt
  --key=/etc/kubernetes/pki/etcd/server.key
  --endpoints=https://127.0.0.1:2379
)

etcdctl() {
  kubectl exec -n "$NAMESPACE" "$ETCD_POD" -- etcdctl "${ETCDCTL_FLAGS[@]}" "$@"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  health)
    echo "Using pod: $ETCD_POD"
    etcdctl endpoint health --cluster -w table
    ;;
  members)
    echo "Using pod: $ETCD_POD"
    etcdctl member list -w table
    ;;
  remove)
    member_id="${1:?'Usage: etcd.sh remove <member-id>'}"
    echo "Removing member $member_id..."
    etcdctl member remove "$member_id"
    echo "Done. Current members:"
    etcdctl member list -w table
    ;;
  add)
    name="${1:?'Usage: etcd.sh add <name> <peer-url>'}"
    peer_url="${2:?'Usage: etcd.sh add <name> <peer-url>'}"
    echo "Adding member $name at $peer_url..."
    etcdctl member add "$name" --peer-urls="$peer_url"
    echo "Done. Current members:"
    etcdctl member list -w table
    ;;
  help|--help|-h)
    sed -n '2,7p' "$0" | sed 's/^# //'
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac
