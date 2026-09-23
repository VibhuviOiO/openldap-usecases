# overlay-features

`memberof`, `ppolicy` and `auditlog` loaded together.

## 1. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 2. Start it

```bash
cd overlay-features
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```

## 3. Watch the overlay steps

Expect `Loading memberof module`, `Adding memberof overlay`, `ppolicy`, `auditlog`.

```bash
docker logs openldap-overlays | grep 'STEP'
```
`auditlog`.

## 4. The modules are loaded

```bash
docker exec openldap-overlays ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=module{0},cn=config olcModuleLoad | grep olcModuleLoad
```
```
olcModuleLoad: {0}memberof.la
olcModuleLoad: {1}refint.la
olcModuleLoad: {2}auditlog.la
olcModuleLoad: {3}ppolicy.la
```
`{N}` is slapd's ordering index, not part of the value.

## 5. The overlays are attached

```bash
docker exec openldap-overlays ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=config '(objectClass=olcOverlayConfig)' dn | grep '^dn:'
```
```
dn: olcOverlay={0}refint,olcDatabase={2}mdb,cn=config
dn: olcOverlay={1}memberof,olcDatabase={2}mdb,cn=config
dn: olcOverlay={2}auditlog,olcDatabase={2}mdb,cn=config
dn: olcOverlay={3}ppolicy,olcDatabase={2}mdb,cn=config
```

## 6. Test memberof

```bash
docker exec -i openldap-overlays ldapadd -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' <<'LDIF'
dn: ou=Groups,dc=example,dc=com
objectClass: organizationalUnit
ou: Groups

dn: uid=alice,dc=example,dc=com
objectClass: inetOrgPerson
uid: alice
cn: Alice
sn: Example
userPassword: AliceP@ss1

dn: cn=admins,ou=Groups,dc=example,dc=com
objectClass: groupOfNames
cn: admins
member: uid=alice,dc=example,dc=com
LDIF
```

```bash
docker exec openldap-overlays ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b uid=alice,dc=example,dc=com memberOf
```
`memberof` wrote it back:
```
memberOf: cn=admins,ou=Groups,dc=example,dc=com
```
Without the overlay this attribute does not exist.

## 7. The audit log recorded it

```bash
docker exec openldap-overlays ls -la /logs/audit.log
docker exec openldap-overlays tail -5 /logs/audit.log
```
One JSON line per write.

## 8. Tear down

```bash
docker compose down -v
```

## What you learned

- Overlays are loaded as modules, then attached to the database
- `refint` ships with `memberof` and keeps `member`/`memberOf` consistent
- The module list uses `{N}` ordering prefixes
- `auditlog` writes to `/logs/audit.log` inside the container

## Notes

- Every overlay step is idempotent: a restart does not add it twice
- Controlled by `ENABLE_MEMBEROF`, `ENABLE_PASSWORD_POLICY`, `ENABLE_AUDIT_LOG`
