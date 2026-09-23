# OpenLDAP Use-Cases

Coverage of the [`openldap-docker`](https://github.com/VibhuviOiO/openldap-docker) image.

Commands live in each use-case README, not here. This file is the index.

Image: [`vibhuvioio/openldap:2.6.10`](https://hub.docker.com/r/vibhuvioio/openldap)

## Test in this order

One at a time: use-cases 1, 2, 3, 4 and 7 all publish port 389.

### Stage 1 — one server, the basics

| # | use-case | port | what it covers |
|---|---|---|---|
| 1 | [idempotency-test](idempotency-test/README.md) | 389 | start, restart, the data stays |
| 2 | [docker-secrets](docker-secrets/README.md) | 389 | the password comes from a file |
| 3 | [tls-enabled](tls-enabled/README.md) | 389, 636 | `ldaps://` and StartTLS |

### Stage 2 — features on that server

| # | use-case | port | what it covers |
|---|---|---|---|
| 4 | [overlay-features](overlay-features/README.md) | 389 | memberof, ppolicy, auditlog |
| 5 | [password-policy-test](password-policy-test/README.md) | 391, 638 | weak passwords refused, lockout |
| 6 | [password-rotation](password-rotation/README.md) | 395 | change the admin password, keep the data |

### Stage 3 — real domains

| # | use-case | port | what it covers |
|---|---|---|---|
| 7 | [vibhuvioio-com-singlenode](vibhuvioio-com-singlenode/README.md) | 389, 636 | custom schema and sample data |
| 8 | [vibhuvi-com-singlenode](vibhuvi-com-singlenode/README.md) | 390, 637 | different DN layout, employee data |

### Stage 4 — more than one server

| # | use-case | port | what it covers |
|---|---|---|---|
| 9 | [oiocloud-com-multinode](oiocloud-com-multinode/README.md) | 392-394, 639-641 | three servers, replication |

### Stage 5 — Kubernetes

| # | use-case | what it covers |
|---|---|---|
| 10 | [kubernetes/00-cluster](kubernetes/00-cluster/README.md) | a cluster on your laptop |
| 11 | [kubernetes/01-single-node](kubernetes/01-single-node/README.md) | one server, three volumes |
| 12 | [kubernetes/02-three-node](kubernetes/02-three-node/README.md) | replication, StatefulSet |
| 13 | [kubernetes/03-helm-chart](kubernetes/03-helm-chart/README.md) | probes, PDB, TLS, backups |

## Conventions

- Every use-case README is numbered from step 1 and ends with `docker compose down -v`.
- Every compose file reads `${LDAP_IMAGE:-openldap:local}`; the use-case README sets it.
- `secrets/*.txt` and `.env.*` are gitignored. Each README creates what it needs.
- Requires Docker with the Compose plugin. Kubernetes use-cases also need `kubectl` and `helm`.

## Why this order

Each stage assumes the one before it: a running server, then where its password
comes from, then encryption, then the overlays and policies that sit on top, then
the domains and the multi-node case, then the same progression inside a cluster.

`password-rotation` sits after `password-policy` because both change how binds are
accepted, and a policy can refuse a new password.
