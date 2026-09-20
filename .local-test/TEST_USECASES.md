# Testing All Use-Cases

## Prerequisites

1. Docker and Docker Compose installed
2. Docker daemon running
3. Access to GitHub Container Registry (GHCR)

## Quick Test Commands

### 1. Docker Secrets Use-Case
```bash
cd docker-secrets
docker-compose up -d
sleep 15
docker exec openldap-secrets ldapsearch -x \
  -D "cn=Manager,dc=example,dc=com" \
  -w "SecureAdminP@ssw0rd123!" \
  -b "dc=example,dc=com" -s base
docker-compose down -v
```

### 2. Overlay Features Use-Case
```bash
cd overlay-features
docker-compose up -d
sleep 20
docker logs openldap-overlays 2>&1 | grep -E "(PASS|FAIL)"
docker-compose down -v
```

### 3. TLS Enabled Use-Case
```bash
cd tls-enabled
docker-compose up -d
sleep 15
# Test LDAPS
LDAPTLS_REQCERT=never docker exec openldap-tls ldapsearch -x \
  -H ldaps://localhost:636 \
  -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" \
  -b "dc=example,dc=com" -s base
# Test StartTLS
docker exec openldap-tls ldapsearch -x -ZZ \
  -H ldap://localhost:389 \
  -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" \
  -b "dc=example,dc=com" -s base
docker-compose down -v
```

### 4. Idempotency Test Use-Case
```bash
cd idempotency-test
docker-compose up -d
sleep 15
# Create test data
docker exec openldap-idempotency ldapadd -x \
  -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" << 'EOF'
dn: ou=Test,dc=example,dc=com
objectClass: organizationalUnit
ou: Test
EOF
# Restart container
docker-compose restart
sleep 15
# Verify data persists
docker exec openldap-idempotency ldapsearch -x \
  -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" \
  -b "ou=Test,dc=example,dc=com" -s base
docker-compose down -v
```

### 5. Vibhuvi Single Node Use-Case
```bash
cd vibhuvi-com-singlenode
docker network create ldap-shared-network 2>/dev/null || true
docker-compose up -d
sleep 15
docker exec openldap-vibhuvi ldapsearch -x \
  -b "dc=vibhuvi,dc=com" -s base
docker-compose down -v
```

### 6. Vibhuvioio Single Node Use-Case
```bash
cd vibhuvioio-com-singlenode
docker network create ldap-shared-network 2>/dev/null || true
docker-compose up -d
sleep 15
docker exec openldap-vibhuvioio ldapsearch -x \
  -b "dc=vibhuvioio,dc=com" -s base
docker-compose down -v
```

### 7. Password Policy Test Use-Case
```bash
cd password-policy-test
docker-compose up -d
sleep 15
docker exec openldap-password-policy ldapsearch -x \
  -b "dc=example,dc=com" -s base
docker-compose down -v
```

### 8. OIO Cloud Multi-Node (Replication) Use-Case
```bash
cd oiocloud-com-multinode
docker network create ldap-shared-network 2>/dev/null || true
docker-compose up -d
sleep 30

# Test node 1
docker exec openldap-oiocloud-node1 ldapsearch -x \
  -b "dc=oiocloud,dc=com" -s base

# Test node 2
docker exec openldap-oiocloud-node2 ldapsearch -x \
  -b "dc=oiocloud,dc=com" -s base

# Test node 3
docker exec openldap-oiocloud-node3 ldapsearch -x \
  -b "dc=oiocloud,dc=com" -s base

docker-compose down -v
```

## Using Makefile

```bash
# Test individual use-cases
make test-all

# Or use the Makefile in each use-case directory
cd overlay-features
make test
```

## Automated Test Script

Save this as `test-usecases.sh` and run it:

```bash
#!/bin/bash
set -e

run_test() {
    local name=$1
    local dir=$2
    local cmd=$3
    echo "Testing: $name"
    cd "$dir"
    docker-compose down -v 2>/dev/null || true
    docker-compose up -d
    sleep 15
    if eval "$cmd"; then
        echo "✓ $name: PASS"
    else
        echo "✗ $name: FAIL"
        docker-compose logs --tail=20
    fi
    docker-compose down -v
    cd -
}

# Run all tests
run_test "Docker Secrets" "docker-secrets" \
    'docker exec openldap-secrets ldapsearch -x -D "cn=Manager,dc=example,dc=com" -w "SecureAdminP@ssw0rd123!" -b "dc=example,dc=com" -s base | grep -q "dn:"'

run_test "Overlay Features" "overlay-features" \
    'docker logs openldap-overlays 2>&1 | grep -q "All overlay tests PASSED"'

run_test "TLS" "tls-enabled" \
    'LDAPTLS_REQCERT=never docker exec openldap-tls ldapsearch -x -H ldaps://localhost:636 -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" -b "dc=example,dc=com" -s base | grep -q "dn:"'

echo "All tests complete!"
```

## Expected Results

| Use-Case | Expected Output |
|----------|----------------|
| docker-secrets | Successful bind with secret password |
| overlay-features | "All overlay tests PASSED" in logs |
| tls-enabled | Successful LDAPS and StartTLS connections |
| idempotency-test | Data persists after restart |
| vibhuvi-com-singlenode | Custom schema and data loaded |
| vibhuvioio-com-singlenode | Mahabharata data loaded |
| password-policy-test | Password policy overlay active |
| oiocloud-com-multinode | All 3 nodes respond, replication works |

## Troubleshooting

### "Cannot connect to Docker daemon"
```bash
# Start Docker Desktop or:
sudo systemctl start docker
```

### "Image not found"
```bash
# Pull the image manually
docker pull ghcr.io/vibhuvioio/openldap:latest
```

### "Container unhealthy"
```bash
# Check logs
docker-compose logs

# May need more wait time
sleep 30
```

### "Network not found"
```bash
# Create the shared network
docker network create ldap-shared-network
```
