# tls-enabled

Serve `ldaps://` on 636 and StartTLS on 389.

## 1. Look at the certificate

```bash
cd tls-enabled
ls -la certs/
openssl x509 -in certs/ldap.crt -noout -subject -dates
```
Self-signed, already in the repository.

## 2. Pick the image

```bash
export LDAP_IMAGE=vibhuvioio/openldap:2.6.10
```

## 3. Start it

```bash
LDAP_IMAGE=$LDAP_IMAGE docker compose up -d
docker compose ps
```

## 4. Watch the TLS step

Expect `Configuring TLS...` then `TLS configured`.

```bash
docker logs openldap-tls | grep -iE 'TLS|ldaps'
```

## 5. The paths reached the config

```bash
docker exec openldap-tls ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  olcTLSCertificateFile olcTLSCertificateKeyFile | grep olcTLS
```
```
olcTLSCertificateFile: /certs/ldap.crt
olcTLSCertificateKeyFile: /certs/ldap.key
```

## 6. slapd listens on 636

Expect a failure. This is what a self-signed certificate looks like:

```bash
docker exec openldap-tls ldapsearch -x -H ldaps://localhost:636 \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b dc=example,dc=com -s base dn
```
```
ldap_sasl_bind(SIMPLE): Can't contact LDAP server (-1)
```

`Can't contact` is misleading: the server is up. The *client* refused the
certificate and dropped the handshake. The server knows why:

```bash
docker logs openldap-tls | grep 'unknown ca'
```
```
conn=1022 TLS: can't accept: error:0A000418:SSL routines::tlsv1 alert unknown ca.
conn=1022 fd=14 closed (TLS negotiation failure)
```

`alert unknown ca` is the client telling the server it does not trust the issuer.

## 7. Tell the client to accept it

Expect the search to succeed this time:

```bash
docker exec openldap-tls env LDAPTLS_REQCERT=never \
  ldapsearch -x -H ldaps://localhost:636 \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b dc=example,dc=com -s base dn
```
```
dn: dc=example,dc=com
result: 0 Success
```

The server log now shows the handshake instead of the alert:

```bash
docker logs openldap-tls | grep 'TLS established'
```
```
conn=1023 op=0 TLS established tls_ssf=256 tls_proto=TLSv1.3 tls_cipher=TLS_AES_256_GCM_SHA384
```

## 8. StartTLS on the plain port

Expect the same entry, over an upgraded 389:

```bash
docker exec openldap-tls env LDAPTLS_REQCERT=never \
  ldapsearch -x -ZZ -H ldap://localhost:389 \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b dc=example,dc=com -s base dn
```
```
dn: dc=example,dc=com
result: 0 Success
```
`-ZZ` requires TLS. It fails if the server does not offer it.

## 9. Plain 389 is still plain

```bash
docker exec openldap-tls ldapsearch -x -H ldap://localhost:389 \
  -D cn=Manager,dc=example,dc=com -w 'AdminPass123!' \
  -b dc=example,dc=com -s base dn
```
Works unencrypted. StartTLS is what upgrades it.

## 10. Tear down

```bash
docker compose down -v
```

## What you learned

- `LDAP_TLS_CERT` and `LDAP_TLS_KEY` write `olcTLSCertificateFile` into `cn=config`
- `ldaps://` is a separate listener on 636; `-ZZ` upgrades 389
- slapd reads the key as uid 55, so a `0400` root-owned mount silently
  breaks every handshake
- `LDAPTLS_REQCERT=never` is for self-signed certificates only

## Notes

- Replace `certs/` with a CA-signed pair before production
- `LDAP_TLS_VERIFY_CLIENT=demand` requires client certificates
