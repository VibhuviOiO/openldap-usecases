# oiocloud-com-multinode

Three providers, `dc=oiocloud,dc=com`, multi-master replication.

## 1. Create the env files

```bash
cd oiocloud-com-multinode
for n in 1 2 3; do cp .env.node$n.example .env.node$n; done
grep -H '^LDAP_DOMAIN\|^SERVER_ID\|^REPLICATION_PEERS' .env.node1 .env.node2 .env.node3
```
Each node has its own `SERVER_ID` and a peer list.

## 2. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 3. Start all three

```bash
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```
Three containers. Host ports 392, 393, 394.

## 4. Each node got its own identity

Expect 1, 2, 3.

```bash
for n in 1 2 3; do
  printf 'node%s ' "$n"
  docker exec openldap-oiocloud-node$n sh -c \
    '. /var/run/openldap/ldap-runtime.env; echo "SERVER_ID=$SERVER_ID"'
done
```

## 5. The replication config

```bash
docker exec openldap-oiocloud-node1 ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=config olcServerID olcSyncrepl 2>/dev/null \
  | grep -E '^olc(ServerID|Syncrepl):'
```
Three `olcServerID` lines (the full SID map), two `olcSyncrepl` (the peers).

## 6. Write on node1

```bash
PW=$(grep '^LDAP_ADMIN_PASSWORD=' .env.node1 | cut -d= -f2-)

docker exec -i openldap-oiocloud-node1 ldapadd -x -H ldap://localhost \
  -D cn=Manager,dc=oiocloud,dc=com -w "$PW" <<'LDIF'
dn: ou=Replicated,dc=oiocloud,dc=com
objectClass: organizationalUnit
ou: Replicated
LDIF
```

## 7. Read from node2 and node3

```bash
for n in 2 3; do
  echo "--- node$n ---"
  docker exec openldap-oiocloud-node$n ldapsearch -x -H ldap://localhost \
    -D cn=Manager,dc=oiocloud,dc=com -w "$PW" \
    -b ou=Replicated,dc=oiocloud,dc=com -s base dn
done
```
Both show it. That is replication.

## 8. All three agree

```bash
for n in 1 2 3; do
  printf 'node%s ' "$n"
  docker exec openldap-oiocloud-node$n ldapsearch -Y EXTERNAL -H ldapi:/// \
    -b dc=oiocloud,dc=com -s base contextCSN 2>/dev/null | grep '^contextCSN:'
done
```
Three identical values means converged.

## 9. Run the validator

```bash
docker exec openldap-oiocloud-node1 /usr/local/bin/scripts/ldapcheck.sh --peers
```
Checks retry string, keepalive, indices, overlay, SID map, convergence.

## 10. Kill a node, write, bring it back

```bash
docker stop openldap-oiocloud-node3

docker exec -i openldap-oiocloud-node1 ldapadd -x -H ldap://localhost \
  -D cn=Manager,dc=oiocloud,dc=com -w "$PW" <<'LDIF'
dn: ou=AfterRestart,dc=oiocloud,dc=com
objectClass: organizationalUnit
ou: AfterRestart
LDIF

docker start openldap-oiocloud-node3
sleep 30
```

```bash
docker exec openldap-oiocloud-node3 ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=oiocloud,dc=com -w "$PW" \
  -b ou=AfterRestart,dc=oiocloud,dc=com -s base dn
```
It caught up on its own.

## 11. Tear down

```bash
docker compose down -v
```

## What you learned

- `SERVER_ID` must be unique per node; duplicates corrupt CSN ordering
- `REPLICATION_PEERS` must not list the node itself, or it loops
- `ldapcheck.sh` verifies the settings that fail silently
- `retry="5 5 300 +"` and `keepalive` are what let a node rejoin unattended

## Notes

- `REPLICATION_SERVER_IDS` gives every node the full SID to URL map
- Writes are accepted by all three; there is no conflict resolution
