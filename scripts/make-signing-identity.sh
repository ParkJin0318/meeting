#!/bin/zsh
set -euo pipefail

NAME="meeting-dev"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ $NAME 신원이 이미 있습니다"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -passout pass:x -out "$tmp/id.p12"

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$tmp/id.p12" -k "$KEYCHAIN" -P x -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ $NAME 생성됨. 첫 codesign에서 키 접근 허용 프롬프트가 뜨면 '항상 허용'을 고르십시오"
else
  echo "✗ 신원이 codesigning 목록에 보이지 않습니다 — 키체인 접근에서 인증서를 확인해 주십시오" >&2
  exit 1
fi
