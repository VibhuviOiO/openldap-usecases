#!/bin/bash
# Test: kubernetes/02-three-node
# Usage: ./test.sh
#
# Requires a running cluster and KUBECONFIG. The workflow installs k3s, then
# calls this.
#
# This use-case is about replication, so the test asserts replication rather
# than just "the pods are Running": a write on one provider must appear on the
# other two, all three must converge on one contextCSN, and a provider that was
# down must catch up afterwards.

set -e

NS=ldap-cluster
PODS=(ldap-0 ldap-1 ldap-2)
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

cd "$(dirname "$0")"

log()  { echo -e "${GREEN}  OK $*${NC}"; }
fail() { echo -e "${RED}  FAIL $*${NC}"; exit 1; }

# `kubectl wait` returns as soon as every pod it can *currently* see is Ready, so
# asking before the controller has created them all can succeed after one. Wait
# for the count first.
wait_for_pod_count() {
    local ns="$1" want="$2"
    for _ in $(seq 1 60); do
        local n
        n=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -ge "$want" ] && return 0
        sleep 3
    done
    return 1
}

# ldapsearch inside a pod, authenticated with the mounted admin secret.
# $1 = pod, $2 = ldapsearch arguments
pod_search() {
    local pod="$1"; shift
    kubectl -n "$NS" exec -c openldap -i "$pod" -- bash -c \
        'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw
         ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw '"$1"
}

# ldapadd inside a pod, LDIF on stdin.
pod_add() {
    local pod="$1"
    kubectl -n "$NS" exec -c openldap -i "$pod" -- bash -c \
        'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw
         ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw'
}

context_csn() {
    kubectl -n "$NS" exec -c openldap "$1" -- \
        ldapsearch -Y EXTERNAL -H ldapi:/// -b dc=example,dc=com -s base contextCSN 2>/dev/null \
        | grep '^contextCSN:' | head -1 | awk '{print $2}'
}

# Poll until $2 is found under $3 on pod $1 (replication is asynchronous).
wait_for_entry() {
    local pod="$1" dn="$2" base="$3"
    for _ in $(seq 1 60); do
        pod_search "$pod" "-b $base -s base dn" | grep -q "^dn: $dn" && return 0
        sleep 3
    done
    return 1
}

echo "==============================================================="
echo "  Test: kubernetes/02-three-node"
echo "==============================================================="

echo ""
echo "-> Clean any previous run"
kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null

echo ""
echo "-> 1-2. Apply and wait for all three"
kubectl apply -f manifests.yaml >/dev/null
wait_for_pod_count "$NS" 3
kubectl -n "$NS" wait --for=condition=Ready pod -l app=ldap --timeout=15m >/dev/null
ready=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c "1/1" || true)
[ "$ready" -eq 3 ] || fail "expected 3 Ready pods, got $ready"
log "3 pods Ready"

bound=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | grep -c Bound || true)
[ "$bound" -eq 9 ] || fail "expected 9 Bound claims (3 per pod), got $bound"
log "9 claims Bound"

echo ""
echo "-> 3. Each pod derived its own SERVER_ID"
for i in 0 1 2; do
    got=$(kubectl -n "$NS" exec -c openldap "ldap-${i}" -- \
        sh -c '. /var/run/openldap/ldap-runtime.env; echo "$SERVER_ID"')
    [ "$got" = "$((i + 1))" ] || fail "ldap-${i} has SERVER_ID=$got, expected $((i + 1))"
done
log "SERVER_ID 1, 2, 3"

echo ""
echo "-> 4. Replication is configured on every provider"
serverids=$(kubectl -n "$NS" exec -c openldap ldap-0 -- \
    ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config 2>/dev/null | grep -c '^olcServerID:' || true)
[ "$serverids" -eq 3 ] || fail "expected 3 olcServerID lines, got $serverids"
syncrepl=$(kubectl -n "$NS" exec -c openldap ldap-0 -- \
    ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config 2>/dev/null | grep -c '^olcSyncrepl:' || true)
[ "$syncrepl" -eq 2 ] || fail "expected 2 olcSyncrepl lines, got $syncrepl"
log "3 olcServerID, 2 olcSyncrepl"

echo ""
echo "-> 5-6. A write on ldap-0 replicates to the other two"
pod_add ldap-0 >/dev/null <<'LDIF'
dn: ou=Cluster,dc=example,dc=com
objectClass: organizationalUnit
ou: Cluster
LDIF
for pod in "${PODS[@]}"; do
    wait_for_entry "$pod" "ou=Cluster,dc=example,dc=com" "ou=Cluster,dc=example,dc=com" \
        || fail "ou=Cluster never reached $pod"
    log "ou=Cluster present on $pod"
done

echo ""
echo "-> 7. All three converge on one contextCSN"
converged=0
for _ in $(seq 1 60); do
    a=$(context_csn ldap-0); b=$(context_csn ldap-1); c=$(context_csn ldap-2)
    if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$b" = "$c" ]; then converged=1; break; fi
    sleep 3
done
[ "$converged" -eq 1 ] || fail "contextCSN did not converge: $a / $b / $c"
log "contextCSN $a on all three"

echo ""
echo "-> 9-11. A provider that was down catches up"
kubectl -n "$NS" delete pod ldap-2 --wait=true >/dev/null
pod_add ldap-0 >/dev/null <<'LDIF'
dn: ou=AfterRestart,dc=example,dc=com
objectClass: organizationalUnit
ou: AfterRestart
LDIF
kubectl -n "$NS" wait --for=condition=Ready pod ldap-2 --timeout=10m >/dev/null
wait_for_entry ldap-2 "ou=AfterRestart,dc=example,dc=com" "ou=AfterRestart,dc=example,dc=com" \
    || fail "ldap-2 did not catch up with the write made while it was down"
log "ldap-2 caught up after restart"

echo ""
echo "==============================================================="
echo -e "${GREEN}  All tests passed!${NC}"
echo "==============================================================="
exit 0
