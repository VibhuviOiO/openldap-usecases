#!/bin/bash
# Test: password-rotation use-case
# Usage: ./test.sh [image_tag]
#
# Mirrors the README steps and asserts the outcome of each one:
#   1. start with the old password in the secret file
#   2. change olcRootPW in cn=config over ldapi://
#   3. the directory now serves the new password and refuses the old one
#   4. update the secret file, restart, and confirm the container comes up
#      healthy instead of crash-looping
#
# Step 4 is the regression this use-case exists for: restarting while the file
# still holds the old password makes startup.sh read bind error 49 as "domain
# missing" and loop forever.

set -e

IMAGE_TAG="${1:-latest}"
IMAGE="vibhuvioio/openldap:${IMAGE_TAG}"
PROJECT="openldap-rotation-test"

OLD_PW='OldP@ssw0rd123!'
NEW_PW='NewP@ssw0rd456!'
CONFIG_PW='ConfigP@ssw0rd123!'

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

cd "$(dirname "$0")"

# Secrets are gitignored; always start from the old password so a repeat local
# run does not inherit the rotated value from the previous run.
mkdir -p secrets logs
printf '%s' "$OLD_PW"    > secrets/admin_password.txt
printf '%s' "$CONFIG_PW" > secrets/config_password.txt

echo "═══════════════════════════════════════════════════════════════"
echo "  Test: Password Rotation"
echo "  Image: $IMAGE"
echo "═══════════════════════════════════════════════════════════════"

cleanup() {
    echo "→ Cleaning up..."
    LDAP_IMAGE="$IMAGE" docker compose -p "$PROJECT" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

dc() { LDAP_IMAGE="$IMAGE" docker compose -p "$PROJECT" "$@"; }

wait_healthy() {
    local tries="${1:-40}"
    for _ in $(seq 1 "$tries"); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' openldap-rotation 2>/dev/null)" = "healthy" ] && return 0
        sleep 3
    done
    return 1
}

# A bind must succeed; anything else (including a missing entry) is a failure.
assert_bind_ok() {
    local pw="$1" label="$2"
    if docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
         -D cn=Manager,dc=example,dc=com -w "$pw" \
         -b dc=example,dc=com -s base dn 2>&1 | grep -q "^dn:"; then
        echo -e "${GREEN}  ✓ $label${NC}"
    else
        echo -e "${RED}  ✗ $label — bind failed${NC}"
        return 1
    fi
}

assert_bind_fails() {
    local pw="$1" label="$2"
    if docker exec openldap-rotation ldapsearch -x -H ldap://localhost \
         -D cn=Manager,dc=example,dc=com -w "$pw" \
         -b dc=example,dc=com -s base dn 2>&1 | grep -q "^dn:"; then
        echo -e "${RED}  ✗ $label — bind unexpectedly succeeded${NC}"
        return 1
    fi
    echo -e "${GREEN}  ✓ $label${NC}"
}

echo ""
echo "→ 1. Start with the old password"
dc up -d
if wait_healthy 40; then
    echo -e "${GREEN}  ✓ Container healthy with old password${NC}"
else
    echo -e "${RED}  ✗ Container never became healthy${NC}"
    dc logs --tail=40
    exit 1
fi
assert_bind_ok "$OLD_PW" "old password binds"

echo ""
echo "→ 2. Change olcRootPW in cn=config"
if docker exec -i openldap-rotation ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIF
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${NEW_PW}
LDIF
then
    echo -e "${GREEN}  ✓ olcRootPW replaced${NC}"
else
    echo -e "${RED}  ✗ ldapmodify failed${NC}"
    exit 1
fi

echo ""
echo "→ 3. Directory serves the new password only (file still holds the old one)"
assert_bind_ok    "$NEW_PW" "new password binds"
assert_bind_fails "$OLD_PW" "old password refused"

echo ""
echo "→ 4. Update the secret file, restart, expect healthy"
# Counted again after the restart: the first boot legitimately logs this once
# when it creates the base domain, so an absolute count proves nothing.
rebootstrap_before=$(dc logs 2>&1 | grep -c "Creating base domain" || true)
printf '%s' "$NEW_PW" > secrets/admin_password.txt
dc restart >/dev/null
if wait_healthy 40; then
    echo -e "${GREEN}  ✓ Healthy after restart with the new password${NC}"
else
    echo -e "${RED}  ✗ Unhealthy after restart${NC}"
    dc logs --tail=40
    exit 1
fi
assert_bind_ok "$NEW_PW" "new password still binds after restart"

# The failure mode this guards: with the file still holding the old password,
# startup.sh reads bind error 49 as "domain missing", logs "Creating base
# domain..." again and restarts in a loop.
rebootstrap_after=$(dc logs 2>&1 | grep -c "Creating base domain" || true)
if [ "$rebootstrap_after" -gt "$rebootstrap_before" ]; then
    echo -e "${RED}  ✗ Startup re-bootstrapped the directory — password/file mismatch${NC}"
    dc logs --tail=20
    exit 1
fi
echo -e "${GREEN}  ✓ Startup did not re-bootstrap the directory${NC}"

restarts=$(docker inspect -f '{{.RestartCount}}' openldap-rotation)
if [ "${restarts:-0}" -gt 0 ]; then
    echo -e "${RED}  ✗ Container restarted $restarts time(s) — crash loop${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ No restarts${NC}"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${GREEN}  ✓ All tests passed!${NC}"
echo "═══════════════════════════════════════════════════════════════"
exit 0
