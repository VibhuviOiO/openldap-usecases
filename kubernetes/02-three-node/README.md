# 02 — Three nodes

Three servers, multi-provider replication. The compose multi-node equivalent.

## 1. Apply

Cluster up and `KUBECONFIG` set first — see [00-cluster](../00-cluster/README.md).

```bash
kubectl apply -f 02-three-node/manifests.yaml
```
Namespace, secret, two services, one StatefulSet.

## 2. Wait for all three

```bash
kubectl -n ldap-cluster get pods,pvc -o wide
```
Want `ldap-0`, `ldap-1`, `ldap-2` all `1/1 Running`.

Nine claims must be `Bound` — three volumes per pod.

## 3. Each pod got its own identity

Expect `1`, `2`, `3`. Derived from the pod name.

```bash
for p in ldap-0 ldap-1 ldap-2; do
  printf '%-8s ' "$p"
  kubectl -n ldap-cluster exec "$p" -- \
    sh -c '. /var/run/openldap/ldap-runtime.env; echo "$SERVER_ID"'
done
```

## 4. Check the replication config

Expect three `olcServerID` lines, two `olcSyncrepl`.

```bash
kubectl -n ldap-cluster exec ldap-0 -- \
  ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
    olcServerID olcSyncrepl 2>/dev/null | grep -E '^olc(ServerID|Syncrepl):'
```

## 5. Write on ldap-0

```bash
kubectl -n ldap-cluster exec -i ldap-0 -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' <<'LDIF'
dn: ou=Cluster,dc=example,dc=com
objectClass: organizationalUnit
ou: Cluster
LDIF
```
Added on one provider only.

## 6. Read it from the other two

```bash
for p in ldap-1 ldap-2; do
  echo "--- $p ---"
  kubectl -n ldap-cluster exec "$p" -- \
    bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
             ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
               -b ou=Cluster,dc=example,dc=com -s base dn'
done
```
Both show the entry. That is replication.

## 7. All three agree on contextCSN

```bash
for p in ldap-0 ldap-1 ldap-2; do
  printf '%-8s ' "$p"
  kubectl -n ldap-cluster exec "$p" -- \
    ldapsearch -Y EXTERNAL -H ldapi:/// -b dc=example,dc=com -s base contextCSN 2>/dev/null \
    | grep '^contextCSN:'
done
```
Three identical values means converged.

## 8. Run the validator

```bash
kubectl -n ldap-cluster exec ldap-0 -- \
  env LDAP_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
  /usr/local/bin/scripts/ldapcheck.sh --peers
```
Checks retry string, keepalive, indices, overlay, SID map, convergence.

## 9. Kill a provider

```bash
kubectl -n ldap-cluster delete pod ldap-2
kubectl -n ldap-cluster wait --for=condition=Ready pod/ldap-2 --timeout=5m
```
It comes back on its own.

## 10. Write while it was away

```bash
kubectl -n ldap-cluster exec -i ldap-0 -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' <<'LDIF'
dn: ou=AfterRestart,dc=example,dc=com
objectClass: organizationalUnit
ou: AfterRestart
LDIF
```

## 11. It caught up

```bash
kubectl -n ldap-cluster exec ldap-2 -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=AfterRestart,dc=example,dc=com -s base dn'
```

## 12. Rebuild a node from scratch

```bash
kubectl -n ldap-cluster delete pod ldap-2
kubectl -n ldap-cluster delete pvc data-ldap-2 config-ldap-2 logs-ldap-2
```
New empty volume, re-initialises, pulls state from peers.

Never move a claim to a different ordinal.

## 13. Delete

```bash
kubectl delete namespace ldap-cluster
```
Deletes the claims too, so the data goes.

Next: [03-helm-chart](../03-helm-chart/README.md)
