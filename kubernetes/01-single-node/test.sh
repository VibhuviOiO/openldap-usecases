#!/bin/bash
# Test: kubernetes/01-single-node
# Usage: ./test.sh
#
# Requires a running cluster and KUBECONFIG (see kubernetes/00-cluster/README.md).
# The workflow installs k3s, then calls this.
#
# Asserts the outcome of every README step, including the two things that are
# easy to get wrong: the initContainer seeding cn=config into an empty claim,
# and data surviving a pod deletion.

set -e

NS=ldap-single
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

admin_pw() {
    kubectl -n "$NS" get secret ldap-auth -o jsonpath='{.data.admin-password}' | base64 -d
}

in_pod() {
    kubectl -n "$NS" exec -c openldap -i deploy/ldap -- \
        bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw
                 ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw '"$1"
}

echo "==============================================================="
echo "  Test: kubernetes/01-single-node"
echo "==============================================================="

echo ""
echo "-> Clean any previous run"
kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null

echo ""
echo "-> 1-2. Apply and wait for Ready"
kubectl apply -f manifests.yaml >/dev/null
wait_for_pod_count "$NS" 1
kubectl -n "$NS" wait --for=condition=Ready pod -l app=ldap --timeout=10m >/dev/null
log "pod Ready"

bound=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | grep -c Bound || true)
[ "$bound" -eq 3 ] || fail "expected 3 Bound claims, got $bound"
log "3 claims Bound"

echo ""
echo "-> 3. cn=config was seeded into the empty claim"
kubectl -n "$NS" logs deploy/ldap -c seed-config 2>/dev/null | grep -q "seeded" \
    || fail "initContainer did not report seeding"
# Counted recursively to match what the initContainer reports; a plain ls of
# slapd.d shows only cn=config and cn=config.ldif.
entries=$(kubectl -n "$NS" exec -c openldap deploy/ldap -- \
    find /etc/openldap/slapd.d -mindepth 1 | wc -l | tr -d ' ')
# >= 9: the initContainer seeds 9, then startup.sh adds monitoring/ACL/indices.
[ "$entries" -ge 9 ] || fail "expected at least 9 cn=config entries, found $entries"
log "seeded $entries entries"

echo ""
echo "-> 4. Server answers on the base DN"
in_pod '-s base -b "" namingContexts' | grep -q "dc=example,dc=com" \
    || fail "namingContexts missing"
log "namingContexts: dc=example,dc=com"

echo ""
echo "-> 5-6. Add an entry and read it back"
kubectl -n "$NS" exec -c openldap -i deploy/ldap -- \
    bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw
             ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' <<'LDIF' >/dev/null
dn: ou=UseCase,dc=example,dc=com
objectClass: organizationalUnit
ou: UseCase
LDIF
in_pod '-b ou=UseCase,dc=example,dc=com -s base dn' | grep -q "^dn: ou=UseCase" \
    || fail "added entry not readable"
log "ou=UseCase readable"

echo ""
echo "-> 7-8. Delete the pod; data must survive"
kubectl -n "$NS" delete pod -l app=ldap --wait=true >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod -l app=ldap --timeout=10m >/dev/null
in_pod '-b ou=UseCase,dc=example,dc=com -s base dn' | grep -q "^dn: ou=UseCase" \
    || fail "entry lost after pod deletion - the claim did not persist"
log "entry survived pod deletion"

echo ""
echo "-> 9. hostPort 1389 reachable from outside the cluster"
if command -v ldapsearch >/dev/null 2>&1; then
    ldapsearch -x -H ldap://localhost:1389 \
        -D cn=Manager,dc=example,dc=com -w "$(admin_pw)" \
        -b dc=example,dc=com -s base dn 2>&1 | grep -q "^dn:" \
        || fail "cannot reach ldap://localhost:1389 (hostPort not published?)"
    log "ldap://localhost:1389 answers"
else
    echo "  (ldapsearch not installed - skipping host reachability)"
fi

echo ""
echo "==============================================================="
echo -e "${GREEN}  All tests passed!${NC}"
echo "==============================================================="
exit 0
