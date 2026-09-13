#!/bin/bash
# 对比探测: 业务域名 SNI + 证书校验 (完全模拟真客户端握手)
set -euo pipefail
ROOT_DIR=/root/cfip-opt

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/dns_update.sh"
source "$ROOT_DIR/lib/proxy.sh"

config_init >/dev/null 2>&1
config_validate >/dev/null 2>&1

fqdn="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
zone_id=$(json_get '.cloudflare.zone_id')

res=$(cf_request "GET" "${cf_api_base}/${zone_id}/dns_records?name=${fqdn}&type=A")
mapfile -t ips < <(echo "$res" | jq -r '.result[].content' | sort -V)

echo "业务域名SNI+证书校验探测 $fqdn 共 ${#ips[@]} 条 | $(date '+%H:%M:%S')"
proxy_stop

for ip in "${ips[@]}"; do
    out=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 8 \
        --resolve "$fqdn:443:$ip" \
        -w '%{time_appconnect}|%{http_code}' "https://$fqdn/" 2>/dev/null) || out="0|000"
    app=$(echo "$out" | cut -d'|' -f1)
    code=$(echo "$out" | cut -d'|' -f2)
    if [[ "$app" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v a="$app" 'BEGIN{exit !(a>0)}'; then
        ms=$(awk -v s="$app" 'BEGIN{printf "%.0f", s*1000}')
        echo "OK    ${ip}  握手=${ms}ms  http=$code"
    else
        echo "FAIL  ${ip}  (连接/证书/握手失败)"
    fi
done

proxy_restart
echo "=== 完成 $(date '+%H:%M:%S') ==="