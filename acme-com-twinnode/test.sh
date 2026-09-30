#!/bin/bash
# Test: ACME twin-node replication.
#
# Asserts the outcome, not the startup: after writing to node1, node2 must serve
# the same data, both must report the same entry count, and both must publish
# the same contextCSN set.
#
# Usage: ./test.sh [image_tag]

set -euo pipefail

IMAGE_TAG="${1:-latest}"
IMAGE="vibhuvioio/openldap:${IMAGE_TAG}"
PROJECT="acme-twinnode-test"
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="$HERE/docker-compose.yml"

BASE_DN="dc=acme,dc=com"
ADMIN_DN="cn=Manager,${BASE_DN}"
LDIF="$HERE/sample/acme_people.ldif"
LDIF2="$HERE/sample/acme_second_writer.ldif"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    docker compose -f "$COMPOSE" -p "$PROJECT" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Test: ACME twin-node replication (2-node N-way mesh)"
echo "Image: $IMAGE"

# The real env files are gitignored, so a fresh clone has only the templates.
# Without this docker compose dies on the missing env_file.
for n in 1 2; do
    [ -f "$HERE/.env.node$n" ] || cp "$HERE/.env.node$n.example" "$HERE/.env.node$n"
done

# Read the admin password from the env file. Parsed, not sourced: the value of
# LDAP_ORGANIZATION contains a space, which bash would try to execute.
ADMIN_PASS=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
        LDAP_ADMIN_PASSWORD=*) ADMIN_PASS="${line#LDAP_ADMIN_PASSWORD=}" ;;
    esac
done < "$HERE/.env.node1"
if [ -z "$ADMIN_PASS" ]; then
    echo "LDAP_ADMIN_PASSWORD is empty in .env.node1" >&2
    exit 1
fi

docker network create ldap-shared-network >/dev/null 2>&1 || true

echo "-> starting the cluster"
LDAP_IMAGE="$IMAGE" docker compose -f "$COMPOSE" -p "$PROJECT" up -d

cid() { docker compose -f "$COMPOSE" -p "$PROJECT" ps -q "openldap-node$1" | head -1; }
c1="$(cid 1)"
c2="$(cid 2)"

# A wait must be blocking: poll the server, not the container state.
wait_ready() {
    local container="$1" label="$2" i out
    for i in $(seq 1 60); do
        out="$(docker exec "$container" ldapsearch -x -LLL \
                 -D "$ADMIN_DN" -w "$ADMIN_PASS" \
                 -b "$BASE_DN" -s base dn 2>/dev/null || true)"
        case "$out" in
            *"dn:"*) echo "   $label answered after $((i * 2))s"; return 0 ;;
        esac
        sleep 2
    done
    echo "   $label never answered" >&2
    return 1
}

echo "-> waiting for both nodes"
wait_ready "$c1" "node1"
wait_ready "$c2" "node2"

count_entries() {
    local container="$1" out
    out="$(docker exec "$container" ldapsearch -x -LLL \
             -D "$ADMIN_DN" -w "$ADMIN_PASS" \
             -b "$BASE_DN" "(objectClass=*)" dn 2>/dev/null || true)"
    printf '%s\n' "$out" | awk '/^dn:/{n++} END{print n+0}'
}

csn_set() {
    local container="$1" out
    out="$(docker exec "$container" ldapsearch -x -LLL \
             -D "$ADMIN_DN" -w "$ADMIN_PASS" \
             -b "$BASE_DN" -s base contextCSN 2>/dev/null || true)"
    printf '%s\n' "$out" | awk '/^contextCSN:/{print $2}' | sort
}

echo "-> writing the sample entries to node1"
# -c so a re-run against existing volumes still adds whatever is missing; the
# assertions below, not ldapadd's exit code, decide pass or fail.
docker exec -i "$c1" ldapadd -c -x -D "$ADMIN_DN" -w "$ADMIN_PASS" < "$LDIF" || true

# Write on node2 as well. This is not decoration: it is what proves the mesh
# replicates in BOTH directions, and it is what makes the two contextCSN sets
# match. Each provider bootstrapped its own base entries under its own sid, so
# until one node accepts a change from the other's sid, node1 carries only sid
# 001 while node2 carries 001 and 002.
echo "-> writing one entry to node2 (the reverse direction)"
docker exec -i "$c2" ldapadd -c -x -D "$ADMIN_DN" -w "$ADMIN_PASS" < "$LDIF2" || true

# The image's create-base-domain.ldif already creates dc=acme,dc=com,
# cn=Manager, ou=People, ou=Group and ou=Services: 5 entries. The two sample
# files add 6 people, so a converged directory holds 11.
EXPECTED=11

echo "-> waiting for replication to converge"
n1=0
n2=0
for i in $(seq 1 30); do
    n1="$(count_entries "$c1")"
    n2="$(count_entries "$c2")"
    if [ "$n1" = "$n2" ] && [ "$n1" -ge "$EXPECTED" ]; then
        echo "   converged after $((i * 2))s"
        break
    fi
    sleep 2
done

failed=0

echo ""
echo "-> Test 1: entry counts agree"
if [ "$n1" = "$n2" ] && [ "$n1" -ge "$EXPECTED" ]; then
    echo -e "${GREEN}ok${NC}  node1=$n1 node2=$n2"
else
    echo -e "${RED}FAIL${NC}  node1=$n1 node2=$n2 (expected equal and >= $EXPECTED)"
    failed=1
fi

echo ""
echo "-> Test 2: both directions replicated"
out="$(docker exec "$c2" ldapsearch -x -LLL \
         -D "$ADMIN_DN" -w "$ADMIN_PASS" \
         -b "uid=alice,ou=People,$BASE_DN" -s base cn 2>/dev/null || true)"
case "$out" in
    *"Alice Anderson"*) echo -e "${GREEN}ok${NC}  alice (written on node1) is on node2" ;;
    *) echo -e "${RED}FAIL${NC}  alice not found on node2"; failed=1 ;;
esac
out="$(docker exec "$c1" ldapsearch -x -LLL \
         -D "$ADMIN_DN" -w "$ADMIN_PASS" \
         -b "uid=frank,ou=People,$BASE_DN" -s base cn 2>/dev/null || true)"
case "$out" in
    *"Frank Foster"*) echo -e "${GREEN}ok${NC}  frank (written on node2) is on node1" ;;
    *) echo -e "${RED}FAIL${NC}  frank not found on node1"; failed=1 ;;
esac

echo ""
echo "-> Test 3: contextCSN sets are identical"
s1="$(csn_set "$c1")"
s2="$(csn_set "$c2")"
if [ -n "$s1" ] && [ "$s1" = "$s2" ]; then
    echo -e "${GREEN}ok${NC}  both nodes publish:"
    printf '%s\n' "$s1" | sed 's/^/      /'
else
    echo -e "${RED}FAIL${NC}  contextCSN differs:"
    printf '      node1: %s\n' "$s1"
    printf '      node2: %s\n' "$s2"
    failed=1
fi

echo ""
if [ "$failed" = 0 ]; then
    echo -e "${GREEN}all twin-node replication tests passed${NC}"
    exit 0
fi
echo -e "${RED}twin-node replication tests failed${NC}"
exit 1
