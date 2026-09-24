# 03 — Helm chart

Same topology as 02, packaged, plus probes, PDB, TLS and backups.

Chart: <https://github.com/VibhuviOiO/openldap-helmchart>

## 1. Add the repo

Cluster up and `KUBECONFIG` set first — see [00-cluster](../00-cluster/README.md).

```bash
helm repo add vibhuvioio https://VibhuviOiO.github.io/openldap-helmchart
helm repo update
```
Skip if you install from a local chart directory.

## 2. Namespace and credentials

```bash
kubectl create namespace ldap-helm

kubectl -n ldap-helm create secret generic ldap-auth \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --from-literal=config-password="$(openssl rand -base64 24)" \
  --from-literal=replication-password="$(openssl rand -base64 24)"
```
Chart never generates passwords; regenerating them breaks replication.

## 3. Install

```bash
helm install ldap vibhuvioio/openldap -n ldap-helm \
  --set auth.existingSecret=ldap-auth --wait
```
`--wait` returns only when all providers are Ready.

## 4. Look at what appeared

```bash
kubectl -n ldap-helm get statefulset,svc,pdb,networkpolicy
kubectl -n ldap-helm get pods,pvc -o wide
```
Nine claims, three pods, PDB `maxUnavailable 1`.

## 5. Read the generated entrypoint

```bash
kubectl -n ldap-helm get statefulset ldap-openldap \
  -o jsonpath='{.spec.template.spec.containers[0].args[0]}'
```
Ordinal becomes `SERVER_ID`; peers and SID map built from it.

## 6. Run the chart's test

```bash
helm test ldap -n ldap-helm
```
Binds, searches, compares contextCSN across all three.

## 7. Write and read

```bash
kubectl -n ldap-helm exec -i ldap-openldap-0 -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' <<'LDIF'
dn: ou=HelmTest,dc=example,dc=com
objectClass: organizationalUnit
ou: HelmTest
LDIF
```

```bash
kubectl -n ldap-helm exec ldap-openldap-1 -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=HelmTest,dc=example,dc=com -s base dn'
```
Second command proves it replicated.

## 8. Run the validator

```bash
kubectl -n ldap-helm exec ldap-openldap-0 -- \
  env LDAP_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
  /usr/local/bin/scripts/ldapcheck.sh --peers
```

## 9. Upgrade in place

```bash
helm upgrade ldap vibhuvioio/openldap -n ldap-helm \
  --set auth.existingSecret=ldap-auth --set backup.enabled=true --wait
```
Data lives in the claims, so it survives.

## 10. Confirm the data survived

```bash
kubectl -n ldap-helm exec ldap-openldap-0 -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=HelmTest,dc=example,dc=com -s base dn'
```

## 11. Run the backup job now

Expect `wrote /backup/ldap-<timestamp>.ldif`.

```bash
kubectl -n ldap-helm create job backup-check --from=cronjob/ldap-openldap-backup
kubectl -n ldap-helm wait --for=condition=complete job/backup-check --timeout=5m
kubectl -n ldap-helm logs job/backup-check
```

## 12. Enable TLS

```bash
kubectl -n ldap-helm create secret tls ldap-tls --cert=tls.crt --key=tls.key

helm upgrade ldap vibhuvioio/openldap -n ldap-helm \
  --set auth.existingSecret=ldap-auth --set tls.enabled=true \
  --set tls.existingSecret=ldap-tls --wait
```
Self-signed is fine; probes fall back to `REQCERT=never`.

## 13. Bind over ldaps

```bash
kubectl -n ldap-helm exec ldap-openldap-0 -- \
  env LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://localhost:636 \
    -D cn=Manager,dc=example,dc=com -y /run/secrets/admin-password \
    -b dc=example,dc=com -s base dn
```

## 14. Uninstall

```bash
helm uninstall ldap -n ldap-helm
kubectl -n ldap-helm get pvc
```
Claims stay behind on purpose, so a reinstall reattaches.

## 15. Delete the data

```bash
kubectl -n ldap-helm delete pvc --all
kubectl delete namespace ldap-helm
```
Nothing is left until you do this.

## Limits to know

- `olcDbMaxSize` hardcoded to 1 GiB — that is the directory ceiling.
- Namespace needs `pod-security.kubernetes.io/enforce=baseline`.
- Multi-master has no conflict resolution; write to one provider.
- Backups are online exports, not crash-consistent snapshots.
