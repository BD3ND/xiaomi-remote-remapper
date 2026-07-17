#!/bin/zsh
set -euo pipefail

identity_name="XiaomiRemoteRemapper Local Code Signing"
login_keychain="$HOME/Library/Keychains/login.keychain-db"

if /usr/bin/security find-identity -v -p codesigning "$login_keychain" 2>/dev/null \
    | /usr/bin/grep -Fq "\"$identity_name\""; then
  echo "signing_identity_ready=$identity_name"
  exit 0
fi

temporary_dir=$(/usr/bin/mktemp -d "/tmp/xiaomi-remote-signing.XXXXXX")
cleanup() {
  /bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT

/usr/bin/openssl req \
  -new \
  -newkey rsa:3072 \
  -nodes \
  -x509 \
  -sha256 \
  -days 3650 \
  -subj "/CN=$identity_name/O=Local Development" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "subjectKeyIdentifier=hash" \
  -keyout "$temporary_dir/private-key.pem" \
  -out "$temporary_dir/certificate.pem"

/usr/bin/security add-trusted-cert \
  -r trustRoot \
  -k "$login_keychain" \
  "$temporary_dir/certificate.pem"
/usr/bin/security import "$temporary_dir/private-key.pem" \
  -k "$login_keychain" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

if ! /usr/bin/security find-identity -v -p codesigning "$login_keychain" \
    | /usr/bin/grep -Fq "\"$identity_name\""; then
  echo "未能创建有效代码签名身份。" >&2
  exit 1
fi

echo "signing_identity_ready=$identity_name"
