#!/usr/bin/env bash
# setup-signing-cert.sh — create a persistent self-signed identity so
# jig's codesign identifier stays stable across rebuilds. Same OpenSSL 3
# + security(1) approach as facet / chord / glance / perch.
#
# jig needs no TCC permission, so retention isn't the motivation here. But
# keeping the family signing flow uniform means the same identity
# (`jig-dev`) is reusable, and a future need for stable identity
# (Hardened Runtime / notarization rehearsal) just works.

set -euo pipefail
cd "$(dirname "$0")"

CN="jig-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

hashes=$(security find-certificate -a -c "$CN" -Z "$KEYCHAIN" \
  2>/dev/null | awk '/SHA-1 hash:/ { print $3 }' || true)
hash_count=$(printf '%s\n' "$hashes" | grep -c . || true)

if [[ "$hash_count" -ge 1 ]]; then
  if [[ "$hash_count" -gt 1 ]]; then
    echo "found $hash_count duplicate \"$CN\" certs — collapsing to one"
    skip=true
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      if $skip; then skip=false; continue; fi
      security delete-certificate -Z "$h" "$KEYCHAIN" >/dev/null 2>&1 || true
    done <<<"$hashes"
  fi
  echo "identity already present: $CN"
  echo -n "$CN" > .signing-id
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

P12PW="jig"
openssl pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$P12PW" -name "$CN" >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PW" -A >/dev/null

echo -n "$CN" > .signing-id
echo "created identity: $CN"
security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
  | grep 'SHA-1 hash' || true
echo "next: ./build.sh && ./install.sh"
