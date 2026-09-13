#!/bin/bash
# 诊断: 当前域名所有解析 A 记录的本地直连连通性
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
max_ms=$(json_get '.verify.max_ms')

res=$(cf_request "GET" "${cf_api_base}/${zone_id}/dns_records?name=${fqdn}&type=A")
mapfile -t ips < <(echo "$res" | jq -r '.result[].content' | sort -V)
[[ "${#ips[@]}" -gt 0 ]] || { echo "无 A 记录"; exit 1; }

echo "检查 $fqdn 共 ${#ips[@]} 条 A 记录 | 阈值 ${max_ms}ms | $(date '+%H:%M:%S')"
proxy_stop

: > /tmp/conn_report
passed=0; failed=0
for ip in "${ips[@]}"; do
    if median=$(ip_verify_one "$ip"); then
        echo "良好  ${ip}  握手=${median}ms"
        echo "$ip ${median} PASS" >> /tmp/conn_report
        passed=$((passed+1))
    else
        echo "失败  ${ip}  超时/断连"
        echo "$ip 99999 FAIL" >> /tmp/conn_report
        failed=$((failed+1))
    fi
done

proxy_restart
echo ""
echo "汇总: 良好 $passed / 失败 $failed"
sort -k2 -n /tmp/conn_report | head -6 | awk '/PASS/{printf "  %s  %sms\n", $1, $2}'
echo "=== 完成 $(date '+%H:%M:%S') ==="