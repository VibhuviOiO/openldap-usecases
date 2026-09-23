# docker-secrets

Run the container with the password in a file instead of an environment variable.

## 1. Create the secret files

```bash
cd docker-secrets
mkdir -p secrets
printf 'AdminP@ssw0rd123!'  > secrets/admin_password.txt
printf 'ConfigP@ssw0rd123!' > secrets/config_password.txt
chmod 600 secrets/*.txt
ls -la secrets/
```
`printf`, not `echo` — no trailing newline.

## 2. Point compose at them

```bash
grep -A4 '^secrets:' docker-compose.yml
```
Expect one name per file:
```
secrets:
  ldap_admin_password:
    file: ./secrets/admin_password.txt
  ldap_config_password:
    file: ./secrets/config_password.txt
```
Each name is backed by a host file. Compose mounts it at `/run/secrets/<name>`.

## 3. The container gets a path, not a value

```bash
grep -B2 -A2 'PASSWORD_FILE' docker-compose.yml
```
Expect:
```
- LDAP_ADMIN_PASSWORD_FILE=/run/secrets/ldap_admin_password
- LDAP_CONFIG_PASSWORD_FILE=/run/secrets/ldap_config_password
```

## 4. Pick the image and start it

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```
One container, initialising.

## 5. Watch the password being loaded

```bash
docker logs -f openldap-secrets
```
Expect these two lines:
```
[INFO]  ℹ️  Loaded LDAP_ADMIN_PASSWORD from /run/secrets/ldap_admin_password
[OK]    ✅ Container is ready
```
`Ctrl-C` to stop following.

**The image opened a file to get the password.** That is the whole use-case.

## 6. The value is not in the environment

```bash
docker exec openldap-secrets env | grep -i password
```
Expect paths only:
```
LDAP_ADMIN_PASSWORD_FILE=/run/secrets/ldap_admin_password
LDAP_CONFIG_PASSWORD_FILE=/run/secrets/ldap_config_password
```

```bash
docker inspect openldap-secrets | grep -i -A2 password
```
Expect the same. There is no value in the container metadata to leak.

## 7. The file inside the container

```bash
docker exec openldap-secrets ls -la /run/secrets/
docker exec openldap-secrets cat /run/secrets/ldap_admin_password
```
Expect the text you wrote in step 1.

## 8. Bind with the secret

```bash
docker exec openldap-secrets ldapsearch -x -H ldap://localhost \
  -D cn=Manager,dc=example,dc=com \
  -y /run/secrets/ldap_admin_password \
  -b dc=example,dc=com -s base dn
```
Expect `dn: dc=example,dc=com`.

`-y <file>` reads the password from the file. `-w 'value'` puts it in `argv`,
where anything on the host can read `/proc/<pid>/cmdline`.

## 9. Tear down

```bash
docker compose down -v
```
Expect the container and the volumes removed.

## What you learned

- A secret is a file on the host, mounted into the container at
  `/run/secrets/<name>`
- The compose `secrets:` block names it; the `*_FILE` variable holds its path
- The image reads the file at startup; the value never enters the environment
- `env` and `docker inspect` show the path, never the value
- `-y file` keeps the password out of the process list; `-w value` does not
- `secrets/*.txt` is gitignored, so a fresh clone must create it first

## Notes

- The image strips CR/LF from the file; `ldapsearch -y` does not, so a file
  ending in a newline breaks `-y` (a Kubernetes Secret often has one)
- Production: Docker Swarm `docker secret`, Kubernetes Secrets, or a vault
- Changing the password later is a separate use-case, not this one
