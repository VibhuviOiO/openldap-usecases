# password-policy-test

`ppolicy` rejects weak passwords and locks accounts.

## 1. Create the env file

```bash
cd password-policy-test
cp .env.password-policy.example .env.password-policy
cat .env.password-policy | grep -v PASSWORD
```
`.env.*` is gitignored, so the copy is what makes it run.

## 2. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 3. Start it

```bash
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```
Host port 391 maps to container 389.

## 4. Watch the policy steps

Expect the ppolicy module, overlay, and the `ou=Policies` entries.

```bash
docker logs openldap-password-policy | grep 'STEP'
```

## 5. The overlay and the default policy

```bash
docker exec openldap-password-policy ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=config '(olcOverlay=ppolicy)' dn | grep '^dn:'
```

```bash
PW=$(grep '^LDAP_ADMIN_PASSWORD=' .env.password-policy | cut -d= -f2-)

docker exec openldap-password-policy ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=test,dc=com -w "$PW" \
  -b cn=default,ou=Policies,dc=test,dc=com
```
Read `pwdMinLength`, `pwdInHistory`, `pwdLockout`, `pwdMaxAge`.

## 6. A weak password is refused

```bash
docker exec -i openldap-password-policy ldapadd -x -H ldap://localhost \
  -D cn=Manager,dc=test,dc=com -w "$PW" <<'LDIF'
dn: uid=bob,dc=test,dc=com
objectClass: inetOrgPerson
uid: bob
cn: Bob
sn: Example
userPassword: bob
LDIF
```
Rejected by the policy, not by the schema.

## 7. A good password is accepted

```bash
docker exec -i openldap-password-policy ldapadd -x -H ldap://localhost \
  -D cn=Manager,dc=test,dc=com -w "$PW" <<'LDIF'
dn: uid=bob,dc=test,dc=com
objectClass: inetOrgPerson
uid: bob
cn: Bob
sn: Example
userPassword: B0b_StrongP@ss123!
LDIF
```
```
adding new entry "uid=bob,dc=test,dc=com"
```

## 8. Bind as that user

```bash
docker exec openldap-password-policy ldapsearch -x -H ldap://localhost \
  -D uid=bob,dc=test,dc=com -w 'B0b_StrongP@ss123!' \
  -b dc=test,dc=com -s base dn
```

## 9. Lock the account with wrong passwords

```bash
for i in 1 2 3 4 5; do
  docker exec openldap-password-policy ldapsearch -x -H ldap://localhost \
    -D uid=bob,dc=test,dc=com -w wrong$i -b dc=test,dc=com -s base dn 2>&1 | tail -1
done
```
After `pwdMaxFailure` attempts: `Invalid credentials (49)` each time, then the
account is locked and even the right password stops working.

## 10. See the lockout attribute

```bash
docker exec openldap-password-policy ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=test,dc=com -w "$PW" \
  -b uid=bob,dc=test,dc=com pwdAccountLockedTime pwdFailureTime
```

## 11. Tear down

```bash
docker compose down -v
```

## What you learned

- `ppolicy` enforces rules on writes, not just on binds
- The policy entry lives at `cn=default,ou=Policies,<base>`
- Failed binds are counted; enough of them lock the account
- The lock is visible as `pwdAccountLockedTime` on the entry

## Notes

- The image creates `ou=Policies` and `cn=default` on first init
- `ENABLE_PASSWORD_POLICY=true` in the env file turns all of this on
