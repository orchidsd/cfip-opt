#!/bin/bash
# 自愈看门狗: 定期检测域名当前解析 IP 是否全部失活
# 连续失败达到阈值 → 自动触发重新优选 (或仅通知), 带 30 分钟冷却防刷屏
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly ROOT_DIR="$(dirname "$SCRIPT_DIR")"
readonly BIN_DIR="$ROOT_DIR/bin"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/dns_update.sh"
source "$ROOT_DIR/lib/notify.sh"

LOCK_DIR="$ROOT_DIR/.watchdog.lock"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# 自愈: /usr/bin/cfip 软链失效(如临时安装目录被清)则重指本项目
repair_cfip_link() {
    local link="/usr/bin/cfip" target="$BIN_DIR/cfip-opt.sh"
    [[ -e "$target" ]] || return 0
    if [[ -L "$link" && "$(readlink "$link" 2>/dev/null)" == "$target" ]]; then
        return 0
    fi
    ln -sf "$target" "$link" 2>/dev/null \
        || { warn "看门狗: 修复 /usr/bin/cfip 软链失败"; return 0; }
    info "看门狗: 修复 /usr/bin/cfip -> $target"
}
repair_cfip_link

config_init >/dev/null 2>&1 || exit 0
config_validate >/dev/null 2>&1 || exit 0

[[ "$(json_get '.watchdog.enabled')" == "true" ]] || exit 0

local_fqdn() {
    local f
    f="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
    [[ -z "$f" || "$f" == "." ]] && f=$(json_get '.cloudflare.hostname' | awk '{print $1}')
    echo "$f"
}

fqdn=$(local_fqdn)
[[ -n "$fqdn" && "$fqdn" != "." ]] || exit 0

max_ms=$(json_get '.verify.max_ms')
port=$(json_get '.port')
[[ "$port" =~ ^(443|8443|2053|2083|2087|2096)$ ]] && scheme="https" || scheme="http"
fail_threshold=$(json_get '.watchdog.fail_consecutive')

# 权威解析: 用 CF API 查当前推送的记录, 绕开 OpenClash 本地 DNS 缓存/fake-ip
# API 查询失败 → 跳过本次, 不计入失败(避免认证/网络抖动误触发)
zone_id=$(json_get '.cloudflare.zone_id')
res=$(cf_request "GET" "${cf_api_base}/${zone_id}/dns_records?name=${fqdn}&type=A,AAAA") \
    || { warn "看门狗: Cloudflare API 查询失败，本次跳过"; exit 0; }
ips=$(echo "$res" | jq -r '.result[].content' 2>/dev/null | sort -u)

healthy=0
if [[ -n "$ips" ]]; then
    checked=0
    for ip in $ips; do
        checked=$(( checked + 1 ))
        [[ "$checked" -gt 12 ]] && break
        t=$(curl -sS -o /dev/null -k --connect-timeout 3 --max-time 5 \
            --resolve "$fqdn:$port:$ip" \
            -w '%{time_total}' "${scheme}://${fqdn}/" 2>/dev/null)
        ms=$(awk -v s="$t" 'BEGIN{ if (s+0 > 0) printf "%.0f", s*1000; else print 99999 }')
        [[ "$ms" -le "$max_ms" ]] && healthy=1
    done
fi

fail=$(cat "$WATCHDOG_FAIL" 2>/dev/null || echo 0)
fail=${fail:-0}

if [[ -n "$ips" && "$healthy" -eq 1 ]]; then
    [[ "$fail" -ne 0 ]] && echo 0 > "$WATCHDOG_FAIL"
    date +%s > "$WATCHDOG_LAST"
    exit 0
fi

fail=$(( fail + 1 ))
echo "$fail" > "$WATCHDOG_FAIL"

if (( fail < fail_threshold )); then
    info "看门狗: $fqdn 当前解析失活 ($fail/$fail_threshold)，持续检测中"
    date +%s > "$WATCHDOG_LAST"
    exit 0
fi

now=$(date +%s)
last=$(cat "$WATCHDOG_RUN_TS" 2>/dev/null || echo 0)
(( now - last >= 1800 )) || exit 0   # 30 分钟冷却期
echo "$now" > "$WATCHDOG_RUN_TS"
echo 0 > "$WATCHDOG_FAIL"

if [[ "$(json_get '.watchdog.auto_run')" == "true" ]]; then
    info "看门狗: $fqdn 解析全部失活(连续${fail_threshold}次)，自动触发重新优选"
    notify_all "域名 $fqdn 当前解析全部失活，已自动触发 Cloudflare 重新优选..."
    nohup bash "$BIN_DIR/cfip-opt.sh" run >> "$LOG_FILE" 2>&1 &
else
    info "看门狗: $fqdn 解析全部失活(连续${fail_threshold}次)，请手动重新优选"
    notify_all "域名 $fqdn 当前解析全部失活，请在软路由手动执行优选"
fi