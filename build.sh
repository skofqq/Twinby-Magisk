#!/bin/sh
# Собирает устанавливаемый zip модуля в out/.
set -eu
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^version=//p' module/module.prop)
OUT=out/twinby-adblock-$VERSION.zip
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -r module/. "$STAGE/"
mkdir -p "$STAGE/system/etc"

{
  echo "# Twinby AdBlock $VERSION"
  echo "127.0.0.1 localhost"
  echo "::1 ip6-localhost"
  echo
  cat lists/*.txt | sed -e 's/#.*//' -e 's/[[:space:]]//g' | grep -v '^$' | sort -u | sed 's/^/0.0.0.0 /'
} > "$STAGE/hosts.base"
cp "$STAGE/hosts.base" "$STAGE/system/etc/hosts"

mkdir -p out
rm -f "$OUT"
(cd "$STAGE" && zip -qr9 "$OLDPWD/$OUT" .)
echo "$OUT ($(grep -c '^0\.0\.0\.0 ' "$STAGE/hosts.base") доменов)"
