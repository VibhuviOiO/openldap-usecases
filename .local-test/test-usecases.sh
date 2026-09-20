#!/bin/bash
# Test all OpenLDAP use-cases with the published Docker image
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

# Create shared network if needed
docker network create ldap-shared-network 2>/dev/null || true

run_test() {
    local name=$1
    local dir=$2
    local cmd=$3
    local wait_time=${4:-15}
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}Testing: $name${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    cd "$dir"
    docker-compose down -v 2>/dev/null || true
    docker-compose up -d
    
    echo "Waiting ${wait_time}s for initialization..."
    sleep "$wait_time"
    
    if eval "$cmd" 2>&1 | grep -q "dn:"; then
        echo -e "${GREEN}✓ $name: PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}✗ $name: FAIL${NC}"
        docker-compose logs --tail=20 2>&1 || true
        ((FAILED++))
    fi
    
    docker-compose down -v
    cd - > /dev/null
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           TESTING ALL USE-CASES                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"

# Test 1: docker-secrets
run_test "Docker Secrets" "docker-secrets" \
    'docker exec openldap-secrets ldapsearch -x -D "cn=Manager,dc=example,dc=com" -w "SecureAdminP@ssw0rd123!" -b "dc=example,dc=com" -s base'

# Test 2: overlay-features (check logs for test results)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Testing: Overlay Features${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cd overlay-features
docker-compose down -v 2>/dev/null || true
docker-compose up -d
echo "Waiting 25s for tests to complete..."
sleep 25
if docker logs openldap-overlays 2>&1 | grep -q "All overlay tests PASSED"; then
    echo -e "${GREEN}✓ Overlay Features: PASS${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ Overlay Features: FAIL${NC}"
    docker-compose logs 2>&1 | tail -30 || true
    ((FAILED++))
fi
docker-compose down -v
cd - > /dev/null

# Test 3: tls-enabled (LDAPS)
run_test "TLS (LDAPS)" "tls-enabled" \
    'LDAPTLS_REQCERT=never docker exec openldap-tls ldapsearch -x -H ldaps://localhost:636 -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" -b "dc=example,dc=com" -s base'

# Test 4: idempotency-test
run_test "Idempotency" "idempotency-test" \
    'docker exec openldap-idempotency ldapsearch -x -D "cn=Manager,dc=example,dc=com" -w "AdminPass123!" -b "dc=example,dc=com" -s base'

# Test 5: vibhuvi-com-singlenode
run_test "Vibhuvi Single Node" "vibhuvi-com-singlenode" \
    'docker exec openldap-vibhuvi ldapsearch -x -b "dc=vibhuvi,dc=com" -s base'

# Test 6: vibhuvioio-com-singlenode
run_test "Vibhuvioio Single Node" "vibhuvioio-com-singlenode" \
    'docker exec openldap-vibhuvioio ldapsearch -x -b "dc=vibhuvioio,dc=com" -s base'

# Test 7: password-policy-test
run_test "Password Policy" "password-policy-test" \
    'docker exec openldap-password-policy ldapsearch -x -b "dc=example,dc=com" -s base'

# Test 8: oiocloud-com-multinode (node1 only for basic test)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Testing: OIO Cloud Multi-Node${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cd oiocloud-com-multinode
docker-compose down -v 2>/dev/null || true
docker-compose up -d
echo "Waiting 30s for cluster initialization..."
sleep 30

ALL_NODES_OK=true
for node in node1 node2 node3; do
    if docker exec openldap-oiocloud-$node ldapsearch -x -b "dc=oiocloud,dc=com" -s base 2>&1 | grep -q "dn:"; then
        echo -e "${GREEN}✓ Node $node: OK${NC}"
    else
        echo -e "${RED}✗ Node $node: FAIL${NC}"
        ALL_NODES_OK=false
    fi
done

if [ "$ALL_NODES_OK" = true ]; then
    echo -e "${GREEN}✓ OIO Cloud Multi-Node: PASS${NC}"
    ((PASSED++))
else
    echo -e "${RED}✗ OIO Cloud Multi-Node: FAIL${NC}"
    ((FAILED++))
fi
docker-compose down -v
cd - > /dev/null

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    TEST SUMMARY                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All use-cases passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some use-cases failed${NC}"
    exit 1
fi
