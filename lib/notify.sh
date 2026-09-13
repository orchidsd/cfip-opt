#!/bin/bash
# ============================================================================
# 通知模块: 通过 Telegram Bot / PushPlus 推送优选结果
# 组装 HTML 消息 -> 逐渠道发送(渠道未启用/未配置则自动跳过)
# 信息源: result.csv(本次优选) + last_summary(上一次对比) + dns_report(执行明细)
# ============================================================================
# shellcheck source=lib/common.sh
: "${LIB_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"
source "$LIB_DIR/common.sh"

# Telegram sendMessage 推送, 要求 enabled+token+user_id 完整, 失败不致命(仅警告)
notify_telegram() {
    local message="$1"
    local enabled token user_id api_host
    enabled=$(json_get '.notifications.telegram.enabled')
    [[ "$enabled" == "true" ]] || return 0

    token=$(json_get '.notifications.telegram.bot_token')
    user_id=$(json_get '.notifications.telegram.user_id')
    api_host=$(json_get '.notifications.telegram.api_host')

    [[ -n "$token" && -n "$user_id" ]] || { warn "Telegram 配置不完整"; return 1; }

    local url="https://${api_host}/sendMessage"
    local data
    data=$(jq -n --arg chat_id "$user_id" --arg text "$message" --arg parse_mode "HTML" \
        '{chat_id: $chat_id, text: $text, parse_mode: $parse_mode}')

    local res
    res=$(curl -sSfL --retry 2 --retry-delay 1 --max-time 20 -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url" 2>/dev/null) || { warn "Telegram 请求超时或失败"; return 1; }

    local ok
    ok=$(echo "$res" | jq -r '.ok // false')
    if [[ "$ok" == "true" ]]; then
        info "Telegram 推送成功"
    else
        warn "Telegram 推送失败: $(echo "$res" | jq -r '.description // "未知错误"')"
    fi
}

# PushPlus 推送(http://www.pushplus.plus/send)
notify_pushplus() {
    local message="$1"
    local enabled token
    enabled=$(json_get '.notifications.pushplus.enabled')
    [[ "$enabled" == "true" ]] || return 0

    token=$(json_get '.notifications.pushplus.token')
    [[ -n "$token" ]] || { warn "PushPlus Token 未配置"; return 1; }

    local data
    data=$(jq -n --arg token "$token" --arg title "Cloudflare 优选 IP 推送" --arg content "$message" --arg template "html" \
        '{token: $token, title: $title, content: $content, template: $template}')

    local res
    res=$(curl -sSfL --retry 2 --retry-delay 1 --max-time 20 -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "http://www.pushplus.plus/send" 2>/dev/null) || { warn "PushPlus 请求超时或失败"; return 1; }

    local code
    code=$(echo "$res" | jq -r '.code // -1')
    if [[ "$code" == "200" ]]; then
        info "PushPlus 推送成功"
    else
        warn "PushPlus 推送失败: $(echo "$res" | jq -r '.msg // "未知错误"')"
    fi
}

# 逐渠道转发同一条消息(每个渠道内部自行判断是否启用)
notify_all() {
    local message="$1"
    notify_telegram "$message"
    notify_pushplus "$message"
}

# 组装 HTML 格式的推送消息并打印(供 notify_all / main 使用)
#   - 固定/浮动池以文字区分; 候选明细带表头; 与上次对比显示 ↑↓ 趋势
notify_build_message() {
    local mode strategy fqdn msg nr mr kd kd_str
    mode=$(json_get '.mode')
    strategy=$(json_get '.cloudflare.strategy')
    fqdn="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
    [[ -z "$fqdn" || "$fqdn" == "." ]] && fqdn=$(json_get '.cloudflare.hostname' | awk '{print $1}')

    msg="<b>Cloudflare 优选 IP 完成</b>\n"
    msg+="<b>时间</b>: $(date '+%F %T')\n"
    msg+="<b>配置</b>: v$(json_get '.ip_version') / :$(json_get '.port') / 验证≤$(json_get '.verify.max_ms')ms"

    if [[ "$mode" == "domain" ]]; then
        nr=$(json_get '.cloudflare.min_records'); mr=$(json_get '.cloudflare.max_records'); kd=$(json_get '.cloudflare.keep_days')
        if [[ "$nr" == "$mr" ]]; then
            kd_str="固定${nr}条 保留${kd}天"
        else
            kd_str="目标${nr}条 上限${mr}条 保留${kd}天"
        fi
        msg+="\n<b>解析</b>: $fqdn ($strategy $kd_str)"
    fi

    if [[ -s "$ROOT_DIR/result.csv" ]]; then
        local top_csv top_lat top_speed cnt
        cnt=$(awk 'END {print NR-1}' "$ROOT_DIR/result.csv")
        top_csv=$(sed -n '2p' "$ROOT_DIR/result.csv")
        top_lat=$(echo "$top_csv" | awk -F, '{print $5}')
        top_speed=$(echo "$top_csv" | awk -F, '{print $6}')

        msg+="\n\n<b>优选结果</b> (候选 $cnt 条)\n<code>\n"
        msg+="$(printf '%-3s %-20s %-6s %-7s %-9s %-4s\n' '#' 'IP' '丢包' '延迟' '速度' '区')\n"
        msg+="$(awk -F, 'NR>1 {printf "%-3s %-20s %-6s %-7s %-9s %-4s\n", NR-1, $1, $4, $5"ms", $6"MB/s", $7}' "$ROOT_DIR/result.csv" | head -n "$(json_get '.speed_test.display_count')")\n"

        if [[ -s "$LAST_SUMMARY" ]]; then
            local prev prev_lat prev_speed dlat trend
            prev=$(tail -n1 "$LAST_SUMMARY")
            prev_lat=$(echo "$prev" | awk -F, '{print $1}')
            prev_speed=$(echo "$prev" | awk -F, '{print $2}')
            [[ "$top_lat" =~ ^[0-9.]+$ ]] || top_lat=0
            [[ "$prev_lat" =~ ^[0-9.]+$ ]] || prev_lat=0
            dlat=$(awk -v a="$prev_lat" -v b="$top_lat" 'BEGIN{printf "%.1f", b-a}')
            trend=$(awk -v d="$dlat" 'BEGIN{if (d<0) print "↓"; else if (d>0) print "↑"; else print "="}')
            msg+="</code>\n<b>较上次</b>: 延迟 ${prev_lat}ms→${top_lat}ms ${trend}(${dlat}ms) · 速度 ${prev_speed}→${top_speed}MB/s"
        else
            msg+="</code>\n<b>基准</b>: 延迟 ${top_lat}ms · 速度 ${top_speed}MB/s (首个基准，下次起对比)"
        fi
        msg+="\n"
    fi

    if [[ -s "$REPORT_FILE" ]]; then
        msg+="\n<b>执行明细</b>\n<code>\n"
        msg+="$(head -n 30 "$REPORT_FILE")\n"
        msg+="</code>\n"
    fi

    printf '%b\n' "$msg"
}