#!/system/bin/sh
# Перед монтированием модулей дописываем в hosts домены из custom.txt.
MODDIR=${0%/*}
HOSTS=$MODDIR/system/etc/hosts
BASE=$MODDIR/hosts.base
CUSTOM=/data/adb/twinby_adblock/custom.txt

[ -f "$BASE" ] || exit 0

{
  cat "$BASE"
  if [ -f "$CUSTOM" ]; then
    echo
    echo "# custom.txt"
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$CUSTOM" | grep -v '^$' | sed 's/^/0.0.0.0 /'
  fi
} > "$HOSTS.tmp" || exit 0

# Перезаписываем на месте, чтобы сохранить SELinux-метку файла
cat "$HOSTS.tmp" > "$HOSTS"
rm -f "$HOSTS.tmp"
chmod 0644 "$HOSTS"
chcon u:object_r:system_file:s0 "$HOSTS" 2>/dev/null
