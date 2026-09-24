#!/bin/bash
set -e

LDAP_URI="ldap://localhost:389"
BASE_DN="${LDAP_BASE_DN:-dc=vibhuvi,dc=com}"
ADMIN_DN="${LDAP_ADMIN_DN:-cn=Manager,${BASE_DN}}"
# Read the password from the container environment instead of hardcoding it.
# The hardcoded value only matched because .env.vibhuvi happened to use it, and
# that file is gitignored - a fresh clone gets the committed template, whose
# password differs, so the import silently loaded nothing.
ADMIN_PW="${LDAP_ADMIN_PASSWORD:-changeme}"

# Secure credential file (avoid password in ps output)
CREDS_FILE=$(mktemp /tmp/ldap_creds.XXXXXX)
chmod 600 "$CREDS_FILE"
printf '%s' "$ADMIN_PW" > "$CREDS_FILE"
trap 'rm -f "$CREDS_FILE"' EXIT

# Wait for LDAP to be ready with proper credentials
echo "⏳ Waiting for LDAP to be ready..."
for i in {1..10}; do
    if ldapsearch -x -H "$LDAP_URI" -b "$BASE_DN" -D "$ADMIN_DN" -y "$CREDS_FILE" -s base dn >/dev/null 2>&1; then
        echo "✅ LDAP is ready"
        break
    fi
    echo "  Attempt $i/10 failed, waiting..."
    sleep 3
done

echo "🔍 Checking if data already exists..."
if ldapsearch -x -H "$LDAP_URI" -b "ou=People,$BASE_DN" -D "$ADMIN_DN" -y "$CREDS_FILE" "(cn=Akira Tanaka)" dn 2>/dev/null | grep -q "^dn:"; then
    echo "✅ Data already exists, skipping initialization"
    exit 0
fi

echo "📥 Loading global employee data..."
ldapadd -x -H "$LDAP_URI" -D "$ADMIN_DN" -y "$CREDS_FILE" -c -f /data/employee_data_global.ldif 2>&1 | grep "^adding new entry" || true

echo "✅ Successfully loaded 28 employees across 8 departments"
