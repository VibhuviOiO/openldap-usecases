#!/bin/bash
# Test: kubernetes/03-helm-chart
# Usage: ./test.sh
#
# Requires a running cluster, KUBECONFIG and helm. The workflow installs k3s and
# helm, then calls this.
#
# Installs the chart exactly as the README documents, then asserts the things
# the chart is responsible for: all providers Ready, the PDB present, the
# chart's own helm test passing, a write replicating, and a rollout that keeps
# the data.

set -e

NS=ldap-helm
RELEASE=ldap
# The published chart only. No local checkout, no sibling repo: this is what a
# user following the README gets.
CHART="vibhuvioio/openldap"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

cd "$(dirname "$0")"

log()  { echo -e "${GREEN}  OK $*${NC}"; }
fail() { echo -e "${RED}  FAIL $*${NC}"; exit 1; }

pod_search() {
    local pod="$1"
    kubectl -n "$NS" exec -c openldap -i "$pod" -- bash -c \
        'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw
         ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw '"$2"
}

echo "==============================================================="
echo "  Test: kubernetes/03-helm-chart"
echo "  Chart: $CHART"
echo "==============================================================="

echo ""
echo "-> Clean any previous run"
helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s >/dev/null

echo ""
echo "-> 1. Resolve the chart"
helm repo add vibhuvioio https://VibhuviOiO.github.io/openldap-helmchart --force-update >/dev/null
helm repo update >/dev/null
helm show chart "$CHART" >/dev/null || fail "cannot resolve chart $CHART"
log "chart resolves"

echo ""
echo "-> 2. Namespace and credentials"
kubectl create namespace "$NS" >/dev/null
kubectl -n "$NS" create secret generic ldap-auth \
    --from-literal=admin-password="$(openssl rand -base64 24)" \
    --from-literal=config-password="$(openssl rand -base64 24)" \
    --from-literal=replication-password="$(openssl rand -base64 24)" >/dev/null
log "secret ldap-auth created"

echo ""
echo "-> 3. helm install --wait"
helm install "$RELEASE" "$CHART" -n "$NS" \
    --set auth.existingSecret=ldap-auth \
    --wait --timeout 15m >/dev/null
log "install returned; all providers Ready"

echo ""
echo "-> 4. What the chart created"
pods=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c "1/1" || true)
[ "$pods" -eq 3 ] || fail "expected 3 Ready providers, got $pods"
log "3 providers Ready"

claims=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | grep -c Bound || true)
[ "$claims" -eq 9 ] || fail "expected 9 Bound claims, got $claims"
log "9 claims Bound"

kubectl -n "$NS" get pdb "${RELEASE}-openldap" >/dev/null 2>&1 \
    || fail "PodDisruptionBudget ${RELEASE}-openldap is missing"
log "PDB present"

echo ""
echo "-> 6. helm test (the chart's own connection test)"
helm test "$RELEASE" -n "$NS" --timeout 10m >/dev/null \
    || { kubectl -n "$NS" get pods -l app.kubernetes.io/component=test -o wide; fail "helm test failed"; }
log "helm test passed"

echo ""
echo "-> 7. Write on one provider, read from another"
kubectl -n "$NS" exec -c openldap -i "${RELEASE}-openldap-0" -- bash -c \
    'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw
     ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' >/dev/null <<'LDIF'
dn: ou=Helm,dc=example,dc=com
objectClass: organizationalUnit
ou: Helm
LDIF
found=0
for _ in $(seq 1 60); do
    pod_search "${RELEASE}-openldap-1" '-b ou=Helm,dc=example,dc=com -s base dn' 2>/dev/null \
        | grep -q "^dn: ou=Helm" && { found=1; break; }
    sleep 3
done
[ "$found" -eq 1 ] || fail "ou=Helm did not replicate to ${RELEASE}-openldap-1"
log "write on -0 visible on -1"

echo ""
echo "-> 10-11. helm upgrade keeps the data"
helm upgrade "$RELEASE" "$CHART" -n "$NS" \
    --set auth.existingSecret=ldap-auth \
    --wait --timeout 15m >/dev/null
pod_search "${RELEASE}-openldap-0" '-b ou=Helm,dc=example,dc=com -s base dn' 2>/dev/null \
    | grep -q "^dn: ou=Helm" || fail "entry lost across helm upgrade"
log "entry survived the upgrade"

echo ""
echo "==============================================================="
echo -e "${GREEN}  All tests passed!${NC}"
echo "==============================================================="
exit 0
