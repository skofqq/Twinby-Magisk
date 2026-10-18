# Установщик прокси-модуля Twinby sync-ad

SKIPUNZIP=0
ui_print "- Twinby AdBlock: sync-ad proxy"

ABI=$(getprop ro.product.cpu.abi)
case "$ABI" in
  arm64*|aarch64) ;;
  *) ui_print "! Этот модуль собран под arm64, а устройство $ABI — не ставьте его."; abort ;;
esac

DATA=/data/adb/twinby_adblock
mkdir -p "$DATA"

# Ключ и сертификат CA переносим в защищённую папку data (переживают обновления модуля)
if [ -f "$MODPATH/ca.key" ]; then
  cp -f "$MODPATH/ca.pem" "$DATA/ca.pem"
  cp -f "$MODPATH/ca.key" "$DATA/ca.key"
  rm -f "$MODPATH/ca.key"   # приватный ключ не держим внутри модуля
fi

# Дефолтный «пустой» ответ рекламы (можно поправить без пересборки)
[ -f "$DATA/sync_ad_response.json" ] || echo '{"ads":[]}' > "$DATA/sync_ad_response.json"

# Режим: сначала безопасный passthrough (ничего не режет), потом block
[ -f "$DATA/mode" ] || echo "passthrough" > "$DATA/mode"

chmod 0700 "$DATA"
chmod 0600 "$DATA/ca.key" 2>/dev/null
chmod 0755 "$MODPATH/bin/adproxy"

ui_print "- Режим: $(cat "$DATA/mode") (сначала проверка, потом включим фильтр)"
ui_print "- Перезагрузите телефон для применения."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/adproxy" 0 0 0755
