#!/system/bin/sh
# Запуск прокси + редирект трафика Twinby + установка CA в доверенные (systemless).
MODDIR=${0%/*}
DATA=/data/adb/twinby_adblock
PKG=com.twinby
PORT=8443

# Ждём загрузку системы
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 5

# --- Доверенный CA (systemless) ---
# Хэш-имя для файла в cacerts
HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$DATA/ca.pem" 2>/dev/null | head -1)
install_ca() {
  DIR="$1"
  [ -d "$DIR" ] || return
  cp -f "$DATA/ca.pem" "$DIR/$HASH.0" 2>/dev/null
  chmod 0644 "$DIR/$HASH.0" 2>/dev/null
  chcon u:object_r:system_file:s0 "$DIR/$HASH.0" 2>/dev/null
}
if [ -n "$HASH" ]; then
  # Android <= 13: системный каталог cacerts (overlay Magisk)
  install_ca /system/etc/security/cacerts
  # Android 14+: хранилище переехало в apex conscrypt — монтируем копию поверх
  if [ -d /apex/com.android.conscrypt/cacerts ]; then
    TMP=/data/adb/twinby_adblock/cacerts_tmp
    rm -rf "$TMP"; mkdir -p "$TMP"
    cp -f /apex/com.android.conscrypt/cacerts/* "$TMP/" 2>/dev/null
    cp -f "$DATA/ca.pem" "$TMP/$HASH.0"
    chmod 0644 "$TMP/"*; chcon u:object_r:system_file:s0 "$TMP/"* 2>/dev/null
    mount --bind "$TMP" /apex/com.android.conscrypt/cacerts 2>/dev/null
    # для процессов, уже видящих /system/etc/security/cacerts
    mount --bind "$TMP" /system/etc/security/cacerts 2>/dev/null
  fi
fi

# --- Запуск прокси ---
MODE=$(cat "$DATA/mode" 2>/dev/null || echo passthrough)
TB_MODE="$MODE" TB_CA_CERT="$DATA/ca.pem" TB_CA_KEY="$DATA/ca.key" \
  TB_AD_RESPONSE="$DATA/sync_ad_response.json" \
  "$MODDIR/bin/adproxy" >> "$DATA/proxy.out" 2>&1 &

sleep 2

# --- Редирект только трафика Twinby на 443 → прокси ---
UID=$(stat -c %u /data/data/$PKG 2>/dev/null)
[ -z "$UID" ] && UID=$(dumpsys package $PKG 2>/dev/null | sed -n 's/.*userId=\([0-9]\+\).*/\1/p' | head -1)
if [ -n "$UID" ]; then
  iptables -t nat -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$UID" -j REDIRECT --to-ports $PORT 2>/dev/null
  iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$UID" -j REDIRECT --to-ports $PORT
fi
