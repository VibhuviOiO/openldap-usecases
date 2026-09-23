# vibhuvioio-com-singlenode

One server, `dc=vibhuvioio,dc=com`, custom schema and sample data loaded at init.

## 1. Create the env file

```bash
cd vibhuvioio-com-singlenode
cp .env.vibhuvioio.example .env.vibhuvioio
grep -v PASSWORD .env.vibhuvioio
```

## 2. Look at what gets loaded

```bash
ls custom-schema/ init/ sample/
```
A schema file, an init script, and an LDIF of entries.

## 3. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 4. Start it

```bash
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```
Host ports 389 and 636.

## 5. Watch the init run

```bash
docker logs openldap-vibhuvioio | tail -40
```
`/docker-entrypoint-initdb.d` runs once, on first init.

## 6. Bind

Expect `dn: dc=vibhuvioio,dc=com`.

```bash
PW=$(grep '^LDAP_ADMIN_PASSWORD=' .env.vibhuvioio | cut -d= -f2-)

docker exec openldap-vibhuvioio ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=vibhuvioio,dc=com -w "$PW" \
  -b dc=vibhuvioio,dc=com -s base dn
```

## 7. The base tree

```bash
docker exec openldap-vibhuvioio ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=vibhuvioio,dc=com -w "$PW" \
  -b dc=vibhuvioio,dc=com -LLL dn | grep '^dn:'
```
Everything the init script added.

## 8. The custom schema is loaded

```bash
docker exec openldap-vibhuvioio ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=schema,cn=config '(objectClass=olcSchemaConfig)' cn 2>/dev/null \
  | grep '^cn:' | tail -6
```
The custom schema appears after the built-in ones.

## 9. Tear down

```bash
docker compose down -v
```

## What you learned

- `/docker-entrypoint-initdb.d` runs scripts and LDIFs on first init only
- `custom-schema/` is mounted read-only and loaded before the data
- The base DN comes from `LDAP_DOMAIN` in the env file
- `down -v` is required to re-run init

## Notes

- The init script is idempotent: a restart does not re-import
- To re-import: `docker compose down -v && docker compose up -d`
