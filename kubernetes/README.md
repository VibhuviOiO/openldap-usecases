# Kubernetes Use Cases

The docker use-cases, with the containers running in a cluster.

## 1. Start the cluster

```bash
docker run -d --name k3s --privileged \
  -p 6443:6443 -p 1389:1389 -p 1689:1689 \
  rancher/k3s:v1.31.4-k3s1 server \
  --disable=traefik --write-kubeconfig-mode=644 --tls-san=127.0.0.1
```
One container. Inside it: API server, scheduler, kubelet, containerd.

This is the `docker compose up` of Kubernetes.

## 2. Take its kubeconfig

```bash
until docker exec k3s test -f /etc/rancher/k3s/k3s.yaml; do sleep 2; done
docker exec k3s cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml
```
`kubectl` now talks to the API server on `127.0.0.1:6443`.

## 3. Confirm

```bash
kubectl get nodes
kubectl get ns
kubectl get sc
```
One node `Ready`, one namespace, a `local-path` StorageClass.

Note `WaitForFirstConsumer` — a claim binds only when a pod wants it.

## 4. Install kubectl if needed

```bash
brew install kubectl
kubectl version --client
```

## 5. One manifest per use-case

```bash
kubectl apply -f 01-single-node/manifests.yaml
kubectl -n ldap-single get pods,pvc -o wide
```
Same shape as `docker compose up -d`, one file per use-case:

| use-case | apply | then look at |
|---|---|---|
| [01-single-node](01-single-node/README.md) | `kubectl apply -f 01-single-node/manifests.yaml` | `kubectl -n ldap-single get pods,pvc` |
| [02-three-node](02-three-node/README.md) | `kubectl apply -f 02-three-node/manifests.yaml` | `kubectl -n ldap-cluster get pods,pvc` |
| [03-helm-chart](03-helm-chart/README.md) | `helm install ldap vibhuvioio/openldap -n ldap-helm --set auth.existingSecret=ldap-auth` | `kubectl -n ldap-helm get statefulset,pdb` |

Each README is the numbered runbook. Follow it.

Each use-case also has a `test.sh` that runs the same steps and asserts the
outcome. CI runs one job per use-case:

```bash
cd 01-single-node && ./test.sh          # needs a cluster and KUBECONFIG
```

## 6. Moving on, and stopping

Moving on: delete the namespace (last step of each use-case README). k3s stays up
and is reused. Never recreate it between use-cases.

All use-cases done:

```bash
kubectl delete namespace ldap-single        # whichever you applied
docker rm -f k3s
```
Removing the container removes every pod and volume with it.

## Four things that differ from compose

**1. An empty volume hides image files.** Compose copies image content into a fresh
named volume. A Kubernetes claim is mounted empty, so the image's 9-file
`cn=config` at `/etc/openldap/slapd.d` is gone and `slapd` exits at once. Both
manifests seed it with an `initContainer`.

**2. Storage is claimed, not mounted.** `./data:/var/lib/ldap` becomes a
`PersistentVolumeClaim`, and it stays `Pending` until a pod consumes it.

**3. The process user matters.** A file mounted `0400`, owned by root, is
unreadable by uid 55. Passwords and TLS keys silently read as empty.

**4. `/run/secrets` collides with the service-account token.** Kubernetes
projects the token at `/var/run/secrets/kubernetes.io/serviceaccount` — inside
that read-only mount:

```
create mountpoint .../kubernetes.io: read-only file system
```

Every pod here sets `automountServiceAccountToken: false`.

## Use k3s, not kind

Same image, same machine:

| runtime | result |
|---|---|
| k3s (containerd 1.7) | works |
| kind (containerd 2.2 / 2.3) | `slapd` grows to 6.9 GiB, OOMKilled |

On kind the log stops at `daemon_init: ldap:/// ldaps:/// ldapi:///` and the pod
stays `CrashLoopBackOff`. Image/runtime problem, not a manifest problem.

## Looking at what the cluster does

```bash
kubectl -n <ns> get pods,pvc -o wide
kubectl -n <ns> describe pod <pod>       # read the Events at the bottom
kubectl -n <ns> logs <pod> -c openldap
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -20
docker logs k3s                          # only if the cluster itself is down
```
