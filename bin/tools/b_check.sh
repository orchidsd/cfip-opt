#!/bin/bash
# 清理惰性 ws_test/ws_path 键 + 停代理下对 mihomo 实际用的三元组做 TLS verify + 恢复代理
set -e
CFG=/root/cfip-opt/conf/config.json
jq 'del(.verify.ws_test, .verify.ws_path)' "$CFG" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CFG"
echo "== verify 配置 =="
jq -c '.verify' "$CFG"

echo "== 停 OpenClash 并验证三元组 =="
/etc/init.d/openclash stop >/dev/null 2>&1 || true
sleep 3
pkill -9 -f "/etc/openclash/clash" 2>/dev/null || true
sleep 1

cd /root/cfip-opt
source lib/common.sh
source lib/config.sh
source lib/dns_update.sh
for ip in 108.162.198.41 104.24.5.11 162.159.32.237; do
    if out=$(ip_verify_one "$ip"); then
        echo "通过 $ip: 中位数=${out}ms"
    else
        echo "剔除 $ip: 探测失败或超阈值"
    fi
done

echo "== 恢复 OpenClash =="
/etc/init.d/openclash start >/dev/null 2>&1 || true
sleep 15
netstat -ltnp 2>/dev/null | grep ':9090 ' || true