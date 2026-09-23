# vibhuvi-com-singlenode

One server, `dc=vibhuvi,dc=com`, custom schema and employee data loaded at init.

## 1. Create the env file

```bash
cd vibhuvi-com-singlenode
cp .env.vibhuvi.example .env.vibhuvi
grep -v PASSWORD .env.vibhuvi
```
Note `LDAP_BASE_DN` and `LDAP_ADMIN_DN` are set explicitly here.

## 2. Look at what gets loaded

```bash
ls custom-schema/ init/
head -20 init/employee_data_global.ldif
```

## 3. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 4. Start it

```bash
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```
Host port 390 maps to container 389.

## 5. Watch the init run

```bash
docker logs openldap-vibhuvi | tail -40
```

## 6. Bind

```bash
PW=$(grep '^LDAP_ADMIN_PASSWORD=' .env.vibhuvi | cut -d= -f2-)

docker exec openldap-vibhuvi ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=vibhuvi,dc=com -w "$PW" \
  -b dc=vibhuvi,dc=com -s base dn
```

## 7. The base tree

```bash
docker exec openldap-vibhuvi ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=vibhuvi,dc=com -w "$PW" \
  -b dc=vibhuvi,dc=com -LLL dn | grep '^dn:'
```

## 8. The employee data landed

```bash
docker exec openldap-vibhuvi ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=vibhuvi,dc=com -w "$PW" \
  -b dc=vibhuvi,dc=com -LLL dn | grep -c '^dn:'
```

## 9. Reach it from your Mac

```bash
ldapsearch -x -H ldap://localhost:390 \
  -D cn=Manager,dc=vibhuvi,dc=com -w "$PW" \
  -b dc=vibhuvi,dc=com -s base dn
```
Container 389 is published on host 390.

## 10. Tear down

```bash
docker compose down -v
```

## What you learned

- `LDAP_BASE_DN` and `LDAP_ADMIN_DN` can override what `LDAP_DOMAIN` derives
- `init/` is copied to `/docker-entrypoint-initdb.d` and runs once
- Publishing 389 on 390 lets several single-node cases run side by side
- `down -v` is how you re-run init

## Notes

- The image derives `cn=Manager,<base>` unless overridden
- Custom schema files are loaded before the data LDIFs
