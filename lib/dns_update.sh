#!/bin/bash
# ============================================================================
# Cloudflare DNS 更新模块 (CF API v4, api token 或 Global Key 认证)
# 核心流程:
#   1. 从 result.csv 读候选 IP 列表
#   2. 逐个 TLS 握手验证(候选 IP + 业务节点域名 SNI, 延迟低、证书合规即通过)
#   3. 重叠优先保留: 与现池相同 IP 原地保留, 不破坏刚恢复的节点
#   4. 增量写入/删除 CF A 记录, 快照旧记录供回滚
#   5. 通知推送由主流程负责(本模块只更新 DNS)
# ============================================================================
# shellcheck source=lib/common.sh
: "${LIB_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"
source "$LIB_DIR/common.sh"

cf_api_base="https://api.cloudflare.com/client/v4/zones"

cf_headers() {
    local email api_key
    email=$(json_get '.cloudflare.email')
    api_key=$(json_get '.cloudflare.api_key')
    printf 'X-Auth-Email: %s\nX-Auth-Key: %s\nContent-Type: application/json' "$email" "$api_key"
}

cf_request() {
    local method="$1" url="$2" data="${3:-}"
    local -a curl_args=(-sSfL --retry 3 --retry-delay 2 --max-time 15 -X "$method")
    local h
    while IFS= read -r h; do
        [[ -n "$h" ]] && curl_args+=(-H "$h")
    done <<< "$(cf_headers)"
    [[ -n "$data" ]] && curl_args+=(-d "$data")
    curl "${curl_args[@]}" "$url"
}

# 修正 /etc/hosts 中 api.cloudflare.com 条目: 先清域名再写固定 IP (防 DNS 污染, 避免重复追加)
cf_hosts_fix() {
    sed -i '/api\.cloudflare\.com/d' /etc/hosts 2>/dev/null || true
    printf '%s\n' \
        "104.18.12.137 api.cloudflare.com" \
        "104.16.160.55 api.cloudflare.com" \
        "104.16.96.55 api.cloudflare.com" >> /etc/hosts
}

cf_verify_credentials() {
    local zone_id
    zone_id=$(json_get '.cloudflare.zone_id')
    local url="${cf_api_base}/${zone_id}"
    local max_retries=5
    local i

    cf_hosts_fix

    for ((i=1; i<=max_retries; i++)); do
        local res
        res=$(cf_request "GET" "$url")
        local success
        success=$(echo "$res" | jq -r '.success // false')
        if [[ "$success" == "true" ]]; then
            info "Cloudflare 认证成功"
            return 0
        fi
        warn "Cloudflare 认证失败，重试 ($i/$max_retries)..."
        cf_hosts_fix
        sleep 2
    done
    die "Cloudflare 认证失败，请检查邮箱、Zone ID、API Key 或网络"
}

# ip_verify_one <IP>: 模拟真客户端探测 — 用业务节点域名做 SNI + 校验证书 + TLS握手延迟中位数
# 节点域名逐个试 (cloudflare.node_domains), 该边缘能对任一节点完成证书合规握手即通过
# TLS 端口: https + time_appconnect (握手完成即止, 不触发 Worker); 非 TLS 端口: http + time_connect
# 通过: 输出中位数(ms)并返回 0; 全失败/无域名证书/超阈值: 返回 1
ip_verify_one() {
    local ip="$1"
    local port scheme max_ms probes var fqdn
    port=$(json_get '.port')
    max_ms=$(json_get '.verify.max_ms')
    probes=$(json_get '.verify.probes')
    [[ "$probes" =~ ^[0-9]+$ && "$probes" -gt 0 ]] || probes=3

    fqdn="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
    [[ -z "$fqdn" || "$fqdn" == "." ]] && fqdn=$(json_get '.cloudflare.hostname' | awk '{print $1}')

    local hosts=() nodes_str
    if [[ "$port" =~ ^(443|8443|2053|2083|2087|2096)$ ]]; then
        scheme="https"; var="time_appconnect"
        nodes_str=$(json_get '.cloudflare.node_domains')
        [[ -n "$nodes_str" ]] && IFS=',' read -r -a hosts <<< "$nodes_str"
        [[ "${#hosts[@]}" -gt 0 ]] || hosts=("$fqdn")
    else
        scheme="http"; var="time_connect"
        hosts=("cloudflare.com")
    fi

    local n p res tms sorted median samples=() k
    for n in "${hosts[@]}"; do
        n=${n//[$'\r\n\t ']/}
        [[ -n "$n" ]] || continue
        samples=()
        for ((p=1; p<=probes; p++)); do
            res=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 8 \
                --resolve "$n:$port:$ip" \
                -w "%{$var}" \
                "${scheme}://${n}/" 2>/dev/null) || res="000"
            [[ "$res" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
            tms=$(awk -v s="$res" 'BEGIN{printf "%.0f", s*1000}')
            (( tms > 0 )) || continue
            samples+=("$tms")
        done
        (( ${#samples[@]} > 0 )) || continue
        sorted=$(printf '%s\n' "${samples[@]}" | sort -n)
        k=$(( (${#samples[@]} + 1) / 2 ))
        median=$(echo "$sorted" | sed -n "${k}p")
        (( median > 0 && median <= max_ms )) || continue
        echo "$median"
        return 0
    done
    return 1
}

ip_verify_run() {
    require_file "$ROOT_DIR/result.csv"

    local ips=()
    mapfile -t ips < <(ip_test_get_ips)

    local enabled
    enabled=$(json_get '.verify.enabled')

    if [[ "$enabled" != "true" ]]; then
        info "推送前验证已禁用，直接推送全部候选 IP"
        printf '%s\n' "${ips[@]}" > "$VERIFIED_FILE"
        return 0
    fi

    info "推送前验证 ${#ips[@]} 个候选 IP (边缘直连)"
    : > "$VERIFIED_FILE"

    local passed=0 failed=0
    local ip
    for ip in "${ips[@]}"; do
        if median=$(ip_verify_one "$ip"); then
            passed=$((passed+1)); info "通过 $ip: 中位数=${median}ms"
            echo "$ip" >> "$VERIFIED_FILE"
        else
            failed=$((failed+1)); warn "剔除 $ip: 探测失败或超阈值"
        fi
    done

    info "验证完成: 通过 $passed, 剔除 $failed"
    echo "验证: 通过 $passed / 剔除 $failed (阈值 $(json_get '.verify.max_ms')ms)" >> "$REPORT_FILE"
    if [[ "$passed" -eq 0 ]]; then
        error "全部候选 IP 未通过验证，保持现有 DNS 不变"
        local fqdn cur_ip
        fqdn="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
        [[ -z "$fqdn" || "$fqdn" == "." ]] && fqdn=$(json_get '.cloudflare.hostname' | awk '{print $1}')
        echo "当前解析保持 (CF 权威记录):" >> "$REPORT_FILE"
        cur_ip=$(cf_request "GET" "${cf_api_base}/$(json_get '.cloudflare.zone_id')/dns_records?name=${fqdn}&type=A,AAAA" 2>/dev/null | jq -r '.result[].content' 2>/dev/null | sort -u)
        [[ -z "$cur_ip" ]] && cur_ip="(无记录或查询失败)"
        echo "$cur_ip" | while IFS= read -r ip; do echo "   $ip" >> "$REPORT_FILE"; done
        notify_all "$(notify_build_message)"
        return 1
    fi
    return 0
}

# iso_age_days <ISO时间戳> <当前epoch>: 计算记录存活天数
iso_age_days() {
    local iso="$1" now="$2" ep
    ep=$(echo "$iso" | awk -F'[-:.TZ]' '{print mktime($1" "$2" "$3" "$4" "$5" "$6)}')
    [[ "$ep" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    echo $(( (now - ep) / 86400 ))
}

dns_update_multi_to_one() {
    local zone_id domain subdomain keep_days max_records min_records
    zone_id=$(json_get '.cloudflare.zone_id')
    domain=$(json_get '.cloudflare.domain')
    subdomain=$(json_get '.cloudflare.subdomain')
    keep_days=$(json_get '.cloudflare.keep_days')
    max_records=$(json_get '.cloudflare.max_records')
    min_records=$(json_get '.cloudflare.min_records')
    [[ "$keep_days" =~ ^[0-9]+$ ]] || keep_days=2
    [[ "$max_records" =~ ^[0-9]+$ && "$max_records" -gt 0 ]] || max_records=10
    [[ "$min_records" =~ ^[0-9]+$ && "$min_records" -gt 0 ]] || min_records=1
    local fqdn="${subdomain}.${domain}"

    local pool_label
    if [[ "$min_records" == "$max_records" ]]; then
        pool_label="固定${min_records}条"
    else
        pool_label="目标${min_records}条 上限${max_records}条"
    fi
    info "模式: 多 IP 轮换池 ($fqdn)  ${pool_label} 保留${keep_days}天"

    local url="${cf_api_base}/${zone_id}/dns_records"
    local params="name=${fqdn}&type=A,AAAA"
    local res
    res=$(cf_request "GET" "${url}?${params}")

    local success
    success=$(echo "$res" | jq -r '.success // false')
    [[ "$success" == "true" ]] || die "获取 DNS 记录失败"

    local records
    records=$(echo "$res" | jq -r '.result')
    [[ "$records" == "null" ]] && records="[]"

    if [[ "$records" != "[]" ]]; then
        echo "$records" | jq -c 'map({name, content, type, modified_on})' > "$SNAPSHOT_FILE"
        info "已保存当前 DNS 快照 (回滚用): $SNAPSHOT_FILE"
    fi

    local new_ips=()
    mapfile -t new_ips < <(cat "$VERIFIED_FILE")

    local now
    now=$(date +%s)
    local kept_file="/tmp/cfip_kept.$$"
    local overlap_file="/tmp/cfip_overlap.$$"
    : > "$kept_file"
    : > "$overlap_file"

    # 现有记录逐条裁决: 本轮新IP(重复) / 失效 / 超期 → 删除; 其余进保留池
    echo "$records" | jq -c '.[]' | while read -r rec; do
        local rid rip mod
        rid=$(echo "$rec" | jq -r '.id')
        rip=$(echo "$rec" | jq -r '.content')
        mod=$(echo "$rec" | jq -r '.modified_on')

        local dup=false newip
        for newip in "${new_ips[@]}"; do
            [[ "$newip" == "$rip" ]] && { dup=true; break; }
        done
        if [[ "$dup" == "true" ]]; then
            info "保留重叠记录 $rip (本轮候选, 不重复创建)"
            echo "$rip" >> "$overlap_file"
            continue
        fi

        local age
        age=$(iso_age_days "$mod" "$now")
        if (( age > keep_days )); then
            cf_request "DELETE" "${url}/${rid}" >/dev/null 2>&1 && { info "删除超期记录 $rip (已${age}天)"; echo "删除超期 $rip (${age}天)" >> "$REPORT_FILE"; }
            continue
        fi

        if ! median=$(ip_verify_one "$rip"); then
            cf_request "DELETE" "${url}/${rid}" >/dev/null 2>&1 && { warn "删除失效记录 $rip"; echo "删除失效 $rip" >> "$REPORT_FILE"; }
            continue
        fi
        info "保留池内记录 $rip (中位数=${median}ms)"
        echo "$age $rid $rip" >> "$kept_file"
    done

    # 池裁决: 重叠IP原地保留, 新IP补剩余槽, 旧记录填缺; 固定池(min==max)收敛到恰好上限
    local keep_count add_count slot_new slot_add slot_keep overlap_count del added pool_now ip rt data
    keep_count=$(wc -l < "$kept_file")
    add_count=${#new_ips[@]}
    if [[ "$min_records" == "$max_records" ]]; then
        slot_new=$(( add_count < max_records ? add_count : max_records ))
    else
        slot_new=$add_count
    fi
    overlap_count=0
    [[ -f "$overlap_file" ]] && overlap_count=$(wc -l < "$overlap_file")
    slot_add=$(( slot_new - overlap_count )); (( slot_add < 0 )) && slot_add=0
    slot_keep=$(( max_records - slot_new )); (( slot_keep < 0 )) && slot_keep=0
    del=$(( keep_count - slot_keep ))
    if (( del > 0 )); then
        local del_done=0 _ age2 rid2 rip2
        while read -r age2 rid2 rip2; do
            if cf_request "DELETE" "${url}/${rid2}" >/dev/null 2>&1; then
                warn "清退最旧 $rip2"
                echo "清退 $rip2" >> "$REPORT_FILE"
                del_done=$((del_done+1))
            fi
        done <<< "$(sort -n "$kept_file" | head -n "$del")"
        keep_count=$(( keep_count - del_done ))
    fi

    # 新增本轮验证通过且不在池内的 IP (重叠已保留, 跳过)
    added=0
    for ip in "${new_ips[@]}"; do
        (( added >= slot_add )) && break
        grep -qx "$ip" "$overlap_file" && continue
        if is_ipv6 "$ip"; then rt="AAAA"; else rt="A"; fi
        data=$(jq -n --arg type "$rt" --arg name "$fqdn" --arg content "$ip" \
            '{type: $type, name: $name, content: $content, ttl: 60, proxied: false}')
        if cf_request "POST" "$url" "$data" | jq -e '.success' >/dev/null 2>&1; then
            info "新增 IP $ip 解析到 $fqdn"
            echo "新增 $ip" >> "$REPORT_FILE"
        else
            warn "IP $ip 解析失败"
            echo "新增失败 $ip" >> "$REPORT_FILE"
        fi
        added=$((added+1))
    done

    pool_now=$(( keep_count + overlap_count + added ))
    if [[ "$min_records" == "$max_records" ]]; then
        echo "池: ${pool_now} 条 (固定${max_records}条)" >> "$REPORT_FILE"
    elif (( pool_now < min_records )); then
        warn "池 ${pool_now} 条低于目标 ${min_records}，持续增量填充"
        echo "池: ${pool_now} 条 (目标≥${min_records}) — 低于目标，继续填充" >> "$REPORT_FILE"
    else
        echo "池: ${pool_now} 条 (目标≥${min_records}, 上限${max_records})" >> "$REPORT_FILE"
    fi

    rm -f "$kept_file" "$overlap_file"
}

dns_update_one_to_one() {
    local zone_id
    zone_id=$(json_get '.cloudflare.zone_id')
    local hostname_str
    hostname_str=$(json_get '.cloudflare.hostname')

    info "模式: 每个优选 IP 解析到对应域名"

    local ips
    mapfile -t ips < <(cat "$VERIFIED_FILE")

    local num=${#ips[@]}
    local hostnames
    IFS=' ' read -r -a hostnames <<< "$hostname_str"

    if [[ "$num" -gt "${#hostnames[@]}" ]]; then
        warn "IP 数量($num)超过域名数量(${#hostnames[@]})，仅处理前 ${#hostnames[@]} 个"
        num=${#hostnames[@]}
    fi

    for ((i=0; i<num; i++)); do
        local CDNhostname="${hostnames[i]}"
        local ipAddr="${ips[i]}"
        info "处理第 $((i+1)) 个: $CDNhostname -> $ipAddr"

        local record_type
        if is_ipv6 "$ipAddr"; then
            record_type="AAAA"
        else
            record_type="A"
        fi

        local list_url="${cf_api_base}/${zone_id}/dns_records?type=${record_type}&name=${CDNhostname}"
        local create_url="${cf_api_base}/${zone_id}/dns_records"

        local list_res
        list_res=$(cf_request "GET" "$list_url")
        local list_success
        list_success=$(echo "$list_res" | jq -r '.success // false')
        [[ "$list_success" == "true" ]] || { warn "获取记录失败: $CDNhostname"; continue; }

        local record_id record_ip
        record_id=$(echo "$list_res" | jq -r '.result[0].id // "null"')
        record_ip=$(echo "$list_res" | jq -r '.result[0].content // ""')

        local res_success=false

        if [[ "$record_ip" == "$ipAddr" ]]; then
            info "IP 无变化，跳过: $CDNhostname"
            res_success=true
        elif [[ "$record_id" == "null" || -z "$record_id" ]]; then
            local data
            data=$(jq -n --arg type "$record_type" --arg name "$CDNhostname" --arg content "$ipAddr" \
                '{type: $type, name: $name, content: $content, proxied: false}')
            local create_res
            create_res=$(cf_request "POST" "$create_url" "$data")
            res_success=$(echo "$create_res" | jq -r '.success // false')
        else
            local update_url="${cf_api_base}/${zone_id}/dns_records/${record_id}"
            local data
            data=$(jq -n --arg type "$record_type" --arg name "$CDNhostname" --arg content "$ipAddr" \
                '{type: $type, name: $name, content: $content, proxied: false}')
            local update_res
            update_res=$(cf_request "PUT" "$update_url" "$data")
            res_success=$(echo "$update_res" | jq -r '.success // false')
        fi

        if [[ "$res_success" == "true" ]]; then
            info "$CDNhostname 更新成功"
            echo "$CDNhostname 更新成功" >> "$LOG_FILE"
            echo "更新 $CDNhostname -> $ipAddr" >> "$REPORT_FILE"
        else
            warn "$CDNhostname 更新失败"
            echo "$CDNhostname 更新失败" >> "$LOG_FILE"
            echo "更新失败 $CDNhostname" >> "$REPORT_FILE"
        fi
        sleep 3
    done
}

dns_update_ip_only() {
    info "模式: 仅输出优选 IP 列表"
    echo "优选 IP 排名如下" > "$LOG_FILE"
    ip_test_get_ips >> "$LOG_FILE"
    cat "$LOG_FILE"
}

dns_update_main() {
    local mode
    mode=$(json_get '.mode')

    : > "$REPORT_FILE"

    # mode=ip 只需本地列结果, 不需要 CF 凭据; domain 才校验凭据并验证候选
    if [[ "$mode" == "domain" ]]; then
        cf_verify_credentials
        ip_verify_run || return 0
    fi

    case "$mode" in
        domain)
            local strategy
            strategy=$(json_get '.cloudflare.strategy')
            if [[ "$strategy" == "one_to_one" ]]; then
                dns_update_one_to_one
            else
                dns_update_multi_to_one
            fi
            ;;
        ip)
            dns_update_ip_only
            ;;
        *)
            die "未知模式: $mode"
            ;;
    esac
}

dns_rollback() {
    local mode strategy
    mode=$(json_get '.mode')
    strategy=$(json_get '.cloudflare.strategy')
    [[ "$mode" == "domain" && "$strategy" == "multi_to_one" ]] || die "仅 multi_to_one 模式支持回滚"

    require_file "$SNAPSHOT_FILE"

    local zone_id domain subdomain fqdn
    zone_id=$(json_get '.cloudflare.zone_id')
    domain=$(json_get '.cloudflare.domain')
    subdomain=$(json_get '.cloudflare.subdomain')
    fqdn="${subdomain}.${domain}"

    local url="${cf_api_base}/${zone_id}/dns_records"
    local res
    res=$(cf_request "GET" "${url}?name=${fqdn}&type=A,AAAA")
    local success
    success=$(echo "$res" | jq -r '.success // false')
    [[ "$success" == "true" ]] || die "获取 DNS 记录失败"

    echo "回滚: $fqdn -> 快照 ${SNAPSHOT_FILE}" > "$REPORT_FILE"

    echo "$res" | jq -c '.result[]' | while read -r rec; do
        local rid
        rid=$(echo "$rec" | jq -r '.id')
        cf_request "DELETE" "${url}/${rid}" >/dev/null 2>&1 && echo "删除当前记录 $(echo "$rec" | jq -r '.content')" >> "$REPORT_FILE"
    done

    cat "$SNAPSHOT_FILE" | jq -c '.[]' | while read -r rec; do
        local rec_type rec_name rec_content rec_data resp r_ok
        rec_type=$(echo "$rec" | jq -r '.type')
        rec_name=$(echo "$rec" | jq -r '.name')
        rec_content=$(echo "$rec" | jq -r '.content')
        rec_data=$(jq -n --arg type "$rec_type" --arg name "$rec_name" --arg content "$rec_content" \
            '{type: $type, name: $name, content: $content, ttl: 60, proxied: false}')
        resp=$(cf_request "POST" "$url" "$rec_data")
        r_ok=$(echo "$resp" | jq -r '.success // false')
        if [[ "$r_ok" == "true" ]]; then
            echo "恢复 $rec_content ($rec_name)" >> "$REPORT_FILE"
        else
            warn "恢复失败 $rec_content: $(echo "$resp" | jq -r '.errors[0].message // "未知错误"')"
        fi
        sleep 3
    done

    notify_all "已回滚 $fqdn 至上一次快照"
    info "回滚完成，查看明细: $REPORT_FILE"
}