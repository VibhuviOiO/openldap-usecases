# password-rotation

Change the LDAP admin password without recreating the database.

Order matters: **the directory first, then the secret file.**

## 1. Create the secret files

```bash
cd password-rotation
mkdir -p secrets
printf 'OldP@ssw0rd123!'    > secrets/admin_password.txt
printf 'ConfigP@ssw0rd123!' > secrets/config_password.txt
chmod 600 secrets/*.txt
```

## 2. Pick the image and start it

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```
Host port 395 maps to container 389.

Expect the old password to bind:

```bash
docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'OldP@ssw0rd123!' \
  -b dc=example,dc=com -s base dn
```
```
dn: dc=example,dc=com
```

## 3. Find where the admin password actually lives

```bash
docker exec openldap-rotation ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  '(olcDatabase={2}mdb)' olcRootDN olcRootPW 2>/dev/null | grep -E '^olc(RootDN|RootPW):'
```
```
olcRootDN: cn=Manager,dc=example,dc=com
olcRootPW: {SSHA}ZoPcmkQOZo0vOfZqO5kBQQvCh17O93u7
```

The bind is checked against `olcRootPW`, not against an entry.

There is an entry with that DN too, but only as `organizationalRole`:

```bash
docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'OldP@ssw0rd123!' \
  -b cn=Manager,dc=example,dc=com objectClass
```
```
objectClass: organizationalRole
```

That class does not permit `userPassword`, which is why editing the entry fails:

```
ldap_modify: Object class violation (65)
	additional info: attribute 'userPassword' not allowed
```

## 4. Change the password in the directory

```bash
docker exec -i openldap-rotation ldapmodify -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: NewP@ssw0rd456!
LDIF
```
```
modifying entry "olcDatabase={2}mdb,cn=config"
```

`-Y EXTERNAL -H ldapi:///` is the container root over the unix socket. It can
write `cn=config`; it cannot write the data database.

## 5. Verify before touching the file

Expect the new password to bind:

```bash
docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'NewP@ssw0rd456!' \
  -b dc=example,dc=com -s base dn
```
```
dn: dc=example,dc=com
```

Expect the old password to be refused:

```bash
docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'OldP@ssw0rd123!' \
  -b dc=example,dc=com -s base dn
```
```
ldap_bind: Invalid credentials (49)
```

Right now the directory serves the new password and the file still holds the old
one. This is the only moment where a restart would break things.

## 6. Update the file

```bash
printf 'NewP@ssw0rd456!' > secrets/admin_password.txt
```

Do not restart before this line — see step 8.

## 7. Restart

```bash
docker compose restart
sleep 20
docker compose ps
```
Expect `Up ... (healthy)` within a few seconds.

```bash
docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com -w 'NewP@ssw0rd456!' \
  -b dc=example,dc=com -s base dn
```
```
dn: dc=example,dc=com
```

```bash
docker logs openldap-rotation | grep -E 'Database already configured|Base domain already exists'
```
```
[INFO]  ℹ️  Database already configured
[INFO]  ℹ️  Base domain already exists
```
Nothing was recreated. That is rotation without downtime for the data.

## 8. Why the order matters

Change the file **without** changing the directory, then restart:

```bash
printf 'AnotherP@ss1!' > secrets/admin_password.txt
docker compose restart
sleep 30
docker compose ps
```
Expect the container to keep restarting, never healthy.

```bash
docker logs openldap-rotation | tail -8
```
```
[INFO]  ℹ️  Database already configured
conn=1002 op=0 BIND dn="cn=Manager,dc=example,dc=com" method=128
conn=1002 op=0 RESULT tag=97 err=49
[STEP]  🔹 Creating base domain...
[WARN]  ⚠️  LDAP operation failed (attempt 1/5), retrying in 2s...
```

`startup.sh` binds with the password from the file. The bind fails, so
`is_base_domain_exists` reports the domain as missing, and it tries to create it
with the same wrong password. Five retries, then startup gives up.

Recover by putting the file back in step with the directory:

```bash
printf 'NewP@ssw0rd456!' > secrets/admin_password.txt
docker compose restart
sleep 20
docker compose ps
```

## 9. Tear down

```bash
docker compose down -v
```

## What you learned

- The admin bind is checked against `olcRootPW` in `cn=config`, not against an entry
- The base entry is `organizationalRole`, so `userPassword` cannot be set on it
- `ldapmodify -Y EXTERNAL -H ldapi:///` writes `cn=config`; the data DB is read-only to it
- Rotate the directory first, then the file, and restart only when they agree
- A restart between the two steps is not recoverable by itself

## Notes

- `LDAP_CONFIG_PASSWORD` is a separate password and is not rotated here
- `olcRootPW` accepts plaintext; slapd stores it as `{SSHA}` on read
- For a schema-level admin, add `simpleSecurityObject` to the entry first, then
  `userPassword` becomes legal
