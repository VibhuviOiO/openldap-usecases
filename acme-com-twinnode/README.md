# acme-com-twinnode

Two OpenLDAP servers in an N-way (multi-provider) mesh, both under `dc=acme,dc=com`.

Ports: `396`/`643` (node1), `397`/`644` (node2).

Use this to check what a **2-node** directory looks like next to
`vibhuvioio-com-singlenode` (1 node) and `oiocloud-com-multinode` (3 nodes).

## 1. Create the env files

The real env files are gitignored, so a fresh clone has only the templates:

```bash
cp .env.node1.example .env.node1
cp .env.node2.example .env.node2
```

`SERVER_ID` must be unique per node and `REPLICATION_PEERS` must never contain
the node itself — the entrypoint refuses to start rather than risk a
replication loop.

## 2. Start the cluster

```bash
docker network create ldap-shared-network 2>/dev/null || true
LDAP_IMAGE=vibhuvioio/openldap:2.6.10 docker compose up -d
```

## 3. Wait until both nodes answer

`docker compose ps` shows container state, not LDAP readiness. Poll the server
until it binds — a base search that returns `dn:` means it is up:

```bash
for p in 396 397; do
  for i in $(seq 1 60); do
    if ldapsearch -x -H ldap://localhost:$p \
         -D "cn=Manager,dc=acme,dc=com" -w 'ChangeMe_StrongP@ssw0rd123!' \
         -b dc=acme,dc=com -s base dn 2>/dev/null | grep -q '^dn:'; then
      echo "port $p is up (after $((i * 2))s)"
      break
    fi
    sleep 2
  done
done
```

## 4. Add records

`ldapadd` on **node1** only. Replication carries them to node2.

```bash
ldapadd -x -H ldap://localhost:396 \
  -D "cn=Manager,dc=acme,dc=com" \
  -w 'ChangeMe_StrongP@ssw0rd123!' \
  -f sample/acme_people.ldif
```

The image's `create-base-domain.ldif` already creates five entries —
`dc=acme,dc=com`, `cn=Manager`, `ou=People`, `ou=Group`, `ou=Services` — so
`ou=People` must **not** be in the file. A sample file that adds it again fails
with `ldap_add: Already exists (68)`.

`sample/acme_people.ldif` adds five `inetOrgPerson` entries (alice, bob, carol,
dave, erin), taking the directory from 5 entries to 10.

## 4b. Write to node2 as well

This step is not decoration — skip it and the two nodes report as **not
converged**:

```bash
ldapadd -x -H ldap://localhost:397 \
  -D "cn=Manager,dc=acme,dc=com" \
  -w 'ChangeMe_StrongP@ssw0rd123!' \
  -f sample/acme_second_writer.ldif
```

Each provider bootstrapped its own base entries under its own sid. node1 wrote
everything with sid `001`; node2 ignored those adds because it already had those
entries, so it never recorded `001` — and node1 never recorded node2's `002`.
Until each side accepts one change from the other's sid, their `contextCSN` sets
differ. One write on node2 closes it, and it is also what proves the mesh
replicates in both directions rather than just one.

After both files the directory holds 11 entries (5 base + 6 people) on each node.

To add one more by hand:

```bash
ldapadd -x -H ldap://localhost:396 \
  -D "cn=Manager,dc=acme,dc=com" -w 'ChangeMe_StrongP@ssw0rd123!' <<'LDIF'
dn: uid=grace,ou=People,dc=acme,dc=com
objectClass: inetOrgPerson
uid: grace
cn: Grace Green
sn: Green
mail: grace@acme.com
userPassword: GracePass123!
LDIF
```

## 5. Prove it replicated

Read each node's write back from the *other* node:

```bash
# alice was written on node1 -> read it from node2
ldapsearch -x -H ldap://localhost:397 \
  -D "cn=Manager,dc=acme,dc=com" -w 'ChangeMe_StrongP@ssw0rd123!' \
  -b "uid=alice,ou=People,dc=acme,dc=com" -s base cn

# frank was written on node2 -> read it from node1
ldapsearch -x -H ldap://localhost:396 \
  -D "cn=Manager,dc=acme,dc=com" -w 'ChangeMe_StrongP@ssw0rd123!' \
  -b "uid=frank,ou=People,dc=acme,dc=com" -s base cn
```

Compare `contextCSN` on both — identical values mean they have converged, and
you should see one line per sid (`001` and `002`):

```bash
for p in 396 397; do
  echo "--- port $p"
  ldapsearch -x -H ldap://localhost:$p \
    -D "cn=Manager,dc=acme,dc=com" -w 'ChangeMe_StrongP@ssw0rd123!' \
    -b dc=acme,dc=com -s base contextCSN | grep '^contextCSN'
done
```

## 6. Stop

```bash
docker compose down          # keep the data
docker compose down -v       # wipe it and start clean
```

## Automated check

```bash
./test.sh 2.6.10
```

Asserts the entry counts agree, that each node's write is readable on the other,
and that both nodes publish the same `contextCSN` set. It tears its own cluster
down.

One caveat: every use-case sets an explicit `container_name`, which is global, so
this cannot run while the same cluster is already up under `docker compose up`.
Stop that first — `docker compose down` keeps the data. The sibling multi-node
use-cases have the same constraint.
