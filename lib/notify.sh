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
    local mode strategy fqdn nr mr kd kd_str iver cnt pv fl
    local msg
    mode=$(json_get '.mode')
    strategy=$(json_get '.cloudflare.strategy')
    fqdn="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
    [[ -z "$fqdn" || "$fqdn" == "." ]] && fqdn=$(json_get '.cloudflare.hostname' | awk '{print $1}')

    iver=$(json_get '.ip_version')
    [[ "$iver" == "ipv6" ]] && iver="IPv6" || iver="IPv4"

    # ---- 信息块: 时间·耗时 / 配置 / 测速源 / 解析 ----
    msg="<b>Cloudflare 优选 IP</b>\n"
    msg+="<b>状态</b>: 完成\n"
    msg+="<b>时间</b>: $(date '+%F %T')"
    if [[ -s "$RUN_START_FILE" ]]; then
        local start now el mins secs
        start=$(<"$RUN_START_FILE")
        now=$(date +%s)
        el=$(( now - start )); (( el < 0 )) && el=0
        mins=$(( el / 60 )); secs=$(( el % 60 ))
        if (( mins > 0 )); then
            msg+=" · 用时 ${mins}分${secs}秒"
        else
            msg+=" · 用时 ${secs}秒"
        fi
        rm -f "$RUN_START_FILE"
    fi
    msg+="\n<b>配置</b>: $iver · :$(json_get '.port') · 验证≤$(json_get '.verify.max_ms')ms"
    if [[ -s "$SPEED_URL_FILE" ]]; then
        local su sl
        IFS='|' read -r su sl < "$SPEED_URL_FILE"
        [[ -n "$su" ]] && msg+="\n<b>测速源</b>: <code>$su</code>($sl)"
    fi
    if [[ "$mode" == "domain" ]]; then
        nr=$(json_get '.cloudflare.min_records'); mr=$(json_get '.cloudflare.max_records'); kd=$(json_get '.cloudflare.keep_days')
        if [[ "$nr" == "$mr" ]]; then
            kd_str="固定${nr}条 保留${kd}天"
        else
            kd_str="目标${nr}条 上限${mr}条 保留${kd}天"
        fi
        msg+="\n<b>解析</b>: $fqdn($strategy $kd_str)"
    fi

    # ---- 排名表格: 竖线分隔(规避中文宽度错位), 区码取第2列 ----
    if [[ -s "$ROOT_DIR/result.csv" ]]; then
        local top_csv top_lat top_speed vline disp
        cnt=$(awk 'END {print NR-1}' "$ROOT_DIR/result.csv")
        top_csv=$(sed -n '2p' "$ROOT_DIR/result.csv")
        top_lat=$(echo "$top_csv" | awk -F, '{print $5}')
        top_speed=$(echo "$top_csv" | awk -F, '{print $6}')

        pv=""; fl=""
        if [[ -s "$REPORT_FILE" ]]; then
            vline=$(grep -m1 '^验证:' "$REPORT_FILE")
            [[ -n "$vline" ]] && {
                pv=$(echo "$vline" | sed -n 's/.*通过 *\([0-9][0-9]*\).*/\1/p')
                fl=$(echo "$vline" | sed -n 's/.*剔除 *\([0-9][0-9]*\).*/\1/p')
            }
        fi

        disp=$(json_get '.speed_test.display_count')
        msg+="\n\n<b>排名</b>(候选 $cnt"
        [[ -n "$pv" ]] && msg+=" · 通过 $pv / 剔除 $fl"
        msg+=")\n<pre>\n"
        # 极窄表头: 全ASCII 1:1对齐, 整行≤32字符保证手机一行放下不折行(丢包基本为0故省略, ms取整, 速度1位)
        msg+="$(printf '%-2s %-15s %-4s %-4s %s\n' '#' 'IP' 'ms' 'MB/s' 'REG')\n"
        # 区码兼容两种 cfst 列布局: 新版 $7=地区码(NRT), 旧版 $7=链接数 -> 回落 $2 国家码
        msg+="$(awk -F, 'NR>1 {zone=$7; if (zone !~ /^[A-Za-z]{2,4}$/) zone=$2; printf "%-2s %-15s %-4s %-4s %s\n", NR-1, $1, int($5), sprintf("%.1f", $6+0), zone}' "$ROOT_DIR/result.csv" | head -n "$disp")\n"
        msg+="</pre>"

        if [[ -s "$LAST_SUMMARY" ]]; then
            local prev prev_lat prev_speed dlat trend
            prev=$(tail -n1 "$LAST_SUMMARY")
            prev_lat=$(echo "$prev" | awk -F, '{print $1}')
            prev_speed=$(echo "$prev" | awk -F, '{print $2}')
            [[ "$top_lat" =~ ^[0-9.]+$ ]] || top_lat=0
            [[ "$prev_lat" =~ ^[0-9.]+$ ]] || prev_lat=0
            dlat=$(awk -v a="$prev_lat" -v b="$top_lat" 'BEGIN{printf "%.1f", b-a}')
            trend=$(awk -v d="$dlat" 'BEGIN{if (d<0) print "↓"; else if (d>0) print "↑"; else print "="}')
            msg+="\n<b>较上次</b>: 延迟 ${prev_lat}ms→${top_lat}ms ${trend}(${dlat}ms) · 速度 ${prev_speed}→${top_speed}MB/s\n"
        else
            msg+="\n<b>基准</b>: 延迟 ${top_lat}ms · 速度 ${top_speed}MB/s (首个基准，下次起对比)\n"
        fi
    fi

    # ---- 执行明细 ----
    if [[ -s "$REPORT_FILE" ]]; then
        msg+="\n<b>执行明细</b>\n<pre>\n"
        msg+="$(head -n 30 "$REPORT_FILE")\n"
        msg+="</pre>\n"
    fi

    printf '%b\n' "$msg"
}