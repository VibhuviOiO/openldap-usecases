# OpenLDAP Use-Cases

Hands-on use-cases for the [`openldap-docker`](https://github.com/VibhuviOiO/openldap-docker) image.

Clone this repository alongside `openldap-docker`:

```bash
git clone https://github.com/VibhuviOiO/openldap-docker.git
git clone https://github.com/VibhuviOiO/openldap-usecases.git
```

## Quick Test

```bash
# Test single use-case
cd docker-secrets
./test.sh

# Test with specific image tag
cd docker-secrets
./test.sh latest
```

## Test All Use-Cases

```bash
for dir in */; do
  [ -f "$dir/test.sh" ] || continue
  echo "Testing: $(basename "$dir")"
  (cd "$dir" && ./test.sh) && echo "✓ PASSED" || echo "✗ FAILED"
done
```

Expected layout:

```text
openldap-usecases/
├── docker-compose.replication.yml
├── docker-secrets/
├── idempotency-test/
├── oiocloud-com-multinode/
├── overlay-features/
├── password-policy-test/
├── tls-enabled/
├── vibhuvi-com-singlenode/
└── vibhuvioio-com-singlenode/
```

## Docker Image

The OpenLDAP image is built and published from the [`openldap-docker`](https://github.com/VibhuviOiO/openldap-docker) repository:

- `vibhuvioio/openldap:latest`
- `vibhuvioio/openldap:2.6.8` (OpenLDAP version)

## Running Use-Cases

All use-cases default to the local image `openldap:local`. Build it first from `../openldap-docker`:

```bash
cd ../openldap-docker
make build
```

Or override the image when running a use-case:

```bash
cd oiocloud-com-multinode
LDAP_IMAGE=vibhuvioio/openldap:latest ./test.sh
```
