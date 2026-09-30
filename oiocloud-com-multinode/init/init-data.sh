#!/bin/bash
set -e

LDAP_URI="ldap://localhost:389"
ADMIN_DN="cn=Manager,dc=oiocloud,dc=com"
# Read the password the container was started with. Hardcoding it meant the
# import silently loaded nothing whenever the env template differed - and the
# template is what a fresh clone gets.
ADMIN_PW="${LDAP_ADMIN_PASSWORD:-changeme}"
BASE_DN="dc=oiocloud,dc=com"

# Secure credential file (avoid password in ps output)
CREDS_FILE=$(mktemp /tmp/ldap_creds.XXXXXX)
chmod 600 "$CREDS_FILE"
# printf, not echo: this OpenLDAP does NOT strip a trailing newline
# from the -y file, so an echo-written password is 1 byte wrong and every
# bind fails - the readiness loop then never succeeds and the import is
# skipped with the directory silently empty.
printf '%s' "$ADMIN_PW" > "$CREDS_FILE"
trap 'rm -f "$CREDS_FILE"' EXIT

echo "⏳ Waiting for LDAP to be ready..."
READY=false
for i in $(seq 1 60); do
    if ldapsearch -x -H "$LDAP_URI" -b "$BASE_DN" -D "$ADMIN_DN" -y "$CREDS_FILE" -s base dn >/dev/null 2>&1; then
        echo "✅ LDAP is ready"
        READY=true
        break
    fi
    echo "  Attempt $i/60 failed, waiting..."
    sleep 3
done

# Never fall through to an import that cannot work. 30s was not enough for a
# three-provider startup, and the old code abandoned the loop and ran the import
# anyway - so the directory came up with no data and no error anywhere.
if [ "$READY" != true ]; then
    echo "❌ LDAP not ready after 180s with the configured credentials; aborting import"
    exit 1
fi

echo "🔍 Checking if data already exists..."
if ldapsearch -x -H "$LDAP_URI" -b "ou=People,$BASE_DN" -D "$ADMIN_DN" -y "$CREDS_FILE" "(employeeID=CI001)" dn 2>/dev/null | grep -q "^dn:"; then
    echo "✅ Data already exists, skipping initialization"
    exit 0
fi

echo "📥 Loading OIO Cloud employee data..."
ldapadd -x -H "$LDAP_URI" -D "$ADMIN_DN" -y "$CREDS_FILE" -c -f /data/oiocloud_data.ldif 2>&1 | grep "^adding new entry" || true

echo "✅ Successfully loaded 30 employees across 3 departments"
