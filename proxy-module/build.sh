#!/bin/sh
# Собирает устанавливаемый zip прокси-модуля: CA + arm64-бинарь + скрипты.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(sed -n 's/^version=//p' proxy-module/module.prop)
OUT="out/twinby-syncad-proxy-$VERSION.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -r proxy-module/. "$STAGE/"
rm -f "$STAGE/build.sh"

# 1) CA (переиспользуем существующий, иначе генерируем свой)
mkdir -p "$STAGE"
if [ -f proxy-module/ca/ca.pem ] && [ -f proxy-module/ca/ca.key ]; then
  cp proxy-module/ca/ca.pem proxy-module/ca/ca.key "$STAGE/"
else
  openssl ecparam -name prime256v1 -genkey -noout -out "$STAGE/ca.key"
  openssl req -x509 -new -key "$STAGE/ca.key" -sha256 -days 3650 \
    -subj "/CN=Twinby AdBlock Local CA/O=twinby-adblock" -out "$STAGE/ca.pem"
fi

# 2) arm64-бинарь прокси (статический, без CGO)
mkdir -p "$STAGE/bin"
( cd proxy && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -trimpath -ldflags="-s -w" -o "$STAGE/bin/adproxy" . )

# 3) упаковка
mkdir -p out
rm -f "$OUT"
( cd "$STAGE" && zip -qr9 "$ROOT/$OUT" . )
echo "$OUT"
