# 01 — Single node

One server, three volumes. The compose single-node equivalent.

## 1. Apply

Cluster up and `KUBECONFIG` set first — see [00-cluster](../00-cluster/README.md).

```bash
kubectl apply -f 01-single-node/manifests.yaml
```
Namespace, secret, three claims, deployment, service.

## 2. Wait for it

```bash
kubectl -n ldap-single get pods,pvc -o wide
```
Want `1/1 Running` and three claims `Bound`.

Still `0/1`? The readiness probe has not passed.

```bash
kubectl -n ldap-single logs deploy/ldap | head -40
```
`startup.sh` configures the database before it reports ready.

## 3. Confirm the volume was seeded

```bash
kubectl -n ldap-single logs deploy/ldap -c seed-config 2>/dev/null
kubectl -n ldap-single exec deploy/ldap -- ls /etc/openldap/slapd.d
```
Empty volume hides the image's `cn=config`. Init copies it back.

## 4. Check the server answers

Expect `namingContexts: dc=example,dc=com`.

```bash
kubectl -n ldap-single exec deploy/ldap -- \
  ldapsearch -x -H ldap://localhost -s base -b "" namingContexts
```

## 5. Add an entry

```bash
kubectl -n ldap-single exec -i deploy/ldap -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' <<'LDIF'
dn: ou=People,dc=example,dc=com
objectClass: organizationalUnit
ou: People
LDIF
```
`printf` strips the trailing newline the mounted secret may carry.

## 6. Read it back

Expect `dn: ou=People,dc=example,dc=com`.

```bash
kubectl -n ldap-single exec deploy/ldap -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=People,dc=example,dc=com -s base dn'
```

## 7. Delete the pod, keep the data

```bash
kubectl -n ldap-single delete pod -l app=ldap
kubectl -n ldap-single wait --for=condition=Ready pod -l app=ldap --timeout=5m
```
Volumes outlive pods; that is the point.

## 8. Entry still there

```bash
kubectl -n ldap-single exec deploy/ldap -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=People,dc=example,dc=com -s base dn'
```
Still `dn: ou=People,dc=example,dc=com`.

## 9. Reach it from your Mac

```bash
kubectl -n ldap-single port-forward svc/ldap 389:389
```
Other terminal:

```bash
ldapsearch -x -H ldap://localhost:389 -D cn=Manager,dc=example,dc=com -W -b dc=example,dc=com
```

## 10. Delete and watch the data go

```bash
kubectl -n ldap-single delete pvc --all
```
Deleting the claims deletes the data.

```bash
kubectl delete namespace ldap-single
```

Next: [02-three-node](../02-three-node/README.md)
