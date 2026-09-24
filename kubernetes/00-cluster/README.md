# 00 — Cluster setup

A single-node cluster on your laptop, and what it is made of.

## 1. Start it

```bash
docker run -d --name k3s --privileged \
  -p 6443:6443 -p 1389:1389 -p 1689:1689 \
  rancher/k3s:v1.31.4-k3s1 server \
  --disable=traefik --write-kubeconfig-mode=644 --tls-san=127.0.0.1
```
`--privileged`: the container runs a second container runtime inside.

`-p 6443:6443`: publishes the API server to your Mac.

`-p 1389:1389 -p 1689:1689`: publishes the LDAP ports the use-cases bind with
`hostPort`, so no `kubectl port-forward` is needed.

## 2. Wait for the kubeconfig

```bash
until docker exec k3s test -f /etc/rancher/k3s/k3s.yaml; do sleep 2; done
```
k3s writes it once the API server is up.

## 3. Copy it out and point kubectl at it

```bash
docker exec k3s cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml
```
Your `~/.kube/config` is untouched.

## 4. Confirm

```bash
kubectl get nodes
```
One node, `Ready`.

Expect the OS and container runtime: `containerd://1.7.23-k3s2`.

```bash
kubectl get nodes -o wide
```

## 5. See what you are running

```bash
kubectl get ns
```
Namespaces — the partitions the use-cases create.

```bash
kubectl get sc
```
Storage classes. `WaitForFirstConsumer` means a claim binds only when a pod
wants it.

```bash
kubectl get pods -A
```
Everything, including `kube-system`.

## 6. What is actually running

```
docker container "k3s"
└── k3s
    ├── API server   :6443   stores all state; kubectl talks to this
    ├── scheduler            picks the node for each pod
    ├── kubelet              starts containers, runs the probes
    └── containerd           pulls images, runs containers
```

The API server is the only writer of state. Everything else watches it.

## 7. When something breaks

```bash
kubectl -n <ns> describe pod <pod>
```
The `Events` at the bottom name the reason.

```bash
kubectl -n <ns> logs <pod> -c openldap
```
What the server itself said.

```bash
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -20
```
Recent history for the namespace.

```bash
docker logs k3s
```
Only if the cluster itself will not start.

## 8. Stop — only after all use-cases

```bash
docker rm -f k3s
```
Takes every pod and volume with it. Between use-cases you only delete the
namespace; the container is never recreated.

## Why k3s and not kind

Same image, same machine:

| runtime | result |
|---|---|
| k3s (containerd 1.7) | works |
| kind (containerd 2.2 / 2.3) | `slapd` grows to 6.9 GiB, OOMKilled |

On kind the log stops at `daemon_init: ldap:/// ldaps:/// ldapi:///`, whatever
`resources.limits.memory` says, and `kubectl describe pod` shows
`Reason: OOMKilled, Exit Code: 137`. Image/runtime problem, not a manifest one.

Next: [01-single-node](../01-single-node/README.md)
