# idempotency-test

Start, restart, restart again. Nothing changes, nothing is duplicated.

## 1. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 2. Start it

```bash
cd idempotency-test
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```

## 3. Watch the first start

Expect `Configuring OpenLDAP` — the full setup ran once.

```bash
docker logs openldap-idempotency | head -30
```

## 4. Count the entries

```bash
docker exec openldap-idempotency ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b dc=example,dc=com -LLL dn | grep -c '^dn:'
```
Remember this number.

## 5. Restart

Expect `Database already configured`. No reconfiguration.

```bash
docker compose restart
sleep 20
docker logs openldap-idempotency | tail -20
```

## 6. Count again

```bash
docker exec openldap-idempotency ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b dc=example,dc=com -LLL dn | grep -c '^dn:'
```
Same number. Nothing was added twice.

## 7. Restart twice more

```bash
docker compose restart && sleep 20 && docker compose restart
sleep 20
docker compose ps
```
Still healthy.

## 8. No duplicate errors anywhere

Expect `0`.

```bash
docker logs openldap-idempotency | grep -ciE 'already exists|duplicate|No such object'
```

## 9. Tear down

```bash
docker compose down -v
```

## What you learned

- `is_database_configured` short-circuits setup on every start after the first
- The database lives in the `ldap-data` volume, so restarts reuse it
- `down -v` deletes the volume; the next start configures from scratch
- Running configuration twice would re-add `cn=config` entries and fail

## Notes

- `init/` is mounted at `/docker-entrypoint-initdb.d` and runs on first init only
- Without `-v`, `down` keeps the volumes and the data
