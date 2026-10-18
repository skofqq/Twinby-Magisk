#!/system/bin/sh
# Полный откат: снять редирект, остановить прокси, убрать данные.
PKG=com.twinby
UID=$(stat -c %u /data/data/$PKG 2>/dev/null)
[ -n "$UID" ] && iptables -t nat -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$UID" -j REDIRECT --to-ports 8443 2>/dev/null
pkill -f adproxy 2>/dev/null
rm -rf /data/adb/twinby_adblock/cacerts_tmp /data/adb/twinby_adblock/proxy.out
