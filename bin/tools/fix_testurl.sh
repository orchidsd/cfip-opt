#!/bin/bash
# 备份并替换 OpenClash 测速 URL: http -> https (edgetunnel worker 拉不起 http)
set -euo pipefail
CFG=/etc/openclash/config.yaml
cp -f "$CFG" "$CFG.bak.http204"
sed -i 's#http://www.gstatic.com/generate_204#https://www.gstatic.com/generate_204#g; s#testUrl:[[:space:]]*http://www.gstatic.com#testUrl: https://www.gstatic.com#' "$CFG"
echo "剩余 http 版: $(grep -c 'http://www.gstatic.com/generate_204' "$CFG" || true)"
echo "现有 https 版: $(grep -c 'https://www.gstatic.com/generate_204' "$CFG" || true)"

echo "== 干净重启 OpenClash =="
/etc/init.d/openclash stop >/dev/null 2>&1 || true
sleep 3
pkill -9 -f "/etc/openclash/clash" 2>/dev/null || true
sleep 1
/etc/init.d/openclash start >/dev/null 2>&1 || true
sleep 15
netstat -ltnp 2>/dev/null | grep -E ':9090 ' || true