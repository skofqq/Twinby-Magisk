# Twinby AdBlock: установщик (выполняется Magisk / KernelSU / APatch)

SKIPUNZIP=0

ui_print "- Twinby AdBlock"

if [ -d /data/adb/modules/hosts ] && [ ! -f /data/adb/modules/hosts/disable ]; then
  ui_print "! Включён встроенный модуль Magisk «Systemless hosts»."
  ui_print "! Он тоже подменяет /system/etc/hosts: отключите его,"
  ui_print "! иначе сработает только один из модулей."
fi

for m in /data/adb/modules/*; do
  [ -f "$m/system/etc/hosts" ] || continue
  case "$m" in */twinby_adblock|*/hosts) continue ;; esac
  [ -f "$m/disable" ] && continue
  ui_print "! Модуль $(basename "$m") тоже подменяет hosts: возможен конфликт."
done

# Пользовательский список доменов переживает обновления модуля
CUSTOM_DIR=/data/adb/twinby_adblock
mkdir -p "$CUSTOM_DIR"
if [ ! -f "$CUSTOM_DIR/custom.txt" ]; then
  cat > "$CUSTOM_DIR/custom.txt" <<'LIST'
# Свои домены для блокировки, по одному на строку.
# Применяются после перезагрузки.
LIST
fi

ui_print "- Блокируется доменов: $(grep -c '^0\.0\.0\.0 ' "$MODPATH/system/etc/hosts")"
ui_print "- Свои домены: $CUSTOM_DIR/custom.txt"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/etc/hosts" 0 0 0644
