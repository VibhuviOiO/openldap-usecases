# 01 — Single node

One server, three volumes. The compose single-node equivalent.

## 1. Apply

Cluster up and `KUBECONFIG` set first — see [00-cluster](../00-cluster/README.md).

```bash
kubectl apply -f 01-single-node/manifests.yaml
```
Namespace, secret, three claims, deployment, service.

## 2. Wait for it

This blocks until Ready — run it before the steps below:

```bash
kubectl -n ldap-single wait --for=condition=Ready pod -l app=ldap --timeout=5m
kubectl -n ldap-single get pods,pvc -o wide
```
```
pod/ldap-...   1/1   Running   0   20s
persistentvolumeclaim/ldap-config   Bound
persistentvolumeclaim/ldap-data     Bound
persistentvolumeclaim/ldap-logs     Bound
```

First run: pod `Pending` ~20s while the three claims provision. No pod Events in
that window is normal — the events are all PVC ones, so `describe pod` shows
`Events: <none>`.

Still `0/1`? The probe has not passed. Look at what it says:

```bash
kubectl -n ldap-single describe pod -l app=ldap | sed -n '/Events:/,$p'
kubectl -n ldap-single logs deploy/ldap | tail -20
```

A probe message worth recognising:

```
Warning  Unhealthy  Startup probe failed:
  FAILED: ldap://localhost:tcp://10.43.42.148:389 is not answering
```

That `tcp://` inside the URL is what `enableServiceLinks: false` disables.
Kubernetes injects `LDAP_PORT=tcp://<cluster-ip>:389` for a Service named `ldap`,
colliding with the image's own `LDAP_PORT`. The server is fine; only the probe is
confused, so the pod never reports Ready.

`startup.sh` configures the database before it reports ready.

## 3. Confirm the volume was seeded

```bash
kubectl -n ldap-single logs deploy/ldap -c seed-config 2>/dev/null
kubectl -n ldap-single exec -c openldap deploy/ldap -- ls /etc/openldap/slapd.d
```
Empty volume hides the image's `cn=config`. Init copies it back.

`-c openldap` on every `exec` below: the pod has an init container, so kubectl
otherwise prints `Defaulted container ... out of: openldap, seed-config` on
stderr — looks like a failure, is not.

## 4. Check the server answers

Expect `namingContexts: dc=example,dc=com`.

```bash
kubectl -n ldap-single exec -c openldap deploy/ldap -- \
  ldapsearch -x -H ldap://localhost -s base -b "" namingContexts
```

## 5. Add an entry

```bash
kubectl -n ldap-single exec -i -c openldap deploy/ldap -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapadd -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw' <<'LDIF'
dn: ou=UseCase,dc=example,dc=com
objectClass: organizationalUnit
ou: UseCase
LDIF
```
```
adding new entry "ou=UseCase,dc=example,dc=com"
```

`printf` strips the trailing newline the mounted secret may carry.

Do not use `ou=People` here: the image creates `ou=People`, `ou=Group` and
`ou=Services` on first init, so adding it again returns `Already exists (68)`.

## 6. Read it back

Expect `dn: ou=UseCase,dc=example,dc=com`.

```bash
kubectl -n ldap-single exec -c openldap deploy/ldap -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=UseCase,dc=example,dc=com -s base dn'
```

## 7. Delete the pod, keep the data

```bash
kubectl -n ldap-single delete pod -l app=ldap
kubectl -n ldap-single wait --for=condition=Ready pod -l app=ldap --timeout=5m
```
Volumes outlive pods; that is the point.

## 8. Entry still there

```bash
kubectl -n ldap-single exec -c openldap deploy/ldap -- \
  bash -c 'printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw; chmod 600 /tmp/pw; \
           ldapsearch -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw \
             -b ou=UseCase,dc=example,dc=com -s base dn'
```
Still `dn: ou=UseCase,dc=example,dc=com`.

## 9. Reach it from your Mac

No `port-forward` needed: the container declares `hostPort: 1389`, and the k3s
container publishes that port. Ports below 1024 need root, hence 1389 not 389.

```bash
ldapsearch -x -H ldap://localhost:1389 \
  -D cn=Manager,dc=example,dc=com -W -b dc=example,dc=com
```
Expect `dn: dc=example,dc=com`.

Password `AdminP@ssw0rd123!`, from the Secret in `manifests.yaml`.

Confirm the port is bound on your Mac:

```bash
lsof -nP -iTCP:1389 -sTCP:LISTEN
```

Nothing listens? k3s was started without `-p 1389:1389`. Recovery only — a normal
run never needs this. Port mappings cannot be added to a running container:

```bash
docker rm -f k3s
```
then re-run step 1 of [00-cluster](../00-cluster/README.md) and re-apply this
manifest. `hostPort` needs the k3s command and the manifest to agree.

## 10. Delete and watch the data go

```bash
kubectl -n ldap-single delete pvc --all
```
Deleting the claims deletes the data.

```bash
kubectl delete namespace ldap-single
```

Next: [02-three-node](../02-three-node/README.md)

The k3s container stays up — 02 reuses it. Never delete it to move on.
