#!/bin/bash
# ============================================================================
# IP 测速模块: 负责 IP 候选列表的维护与调用 CloudflareST(cfst) 测速
#   - 列表: 从 cfst 压缩包自带或镜像更新 ip.txt / ipv6.txt, 定期检查过期自动刷新
#   - 测速: 组装 cfst 参数(TLS 端口/下载测速/httping/colo/筛选阈值)并执行
#   - 产物: $ROOT_DIR/result.csv (候选IP延迟/速度/丢包排名)
# ============================================================================
# shellcheck source=lib/common.sh
: "${LIB_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"
source "$LIB_DIR/common.sh"

# 未配置 colo(地区)时的默认选择: 亚太+美西骨干节点(实测延迟/稳定性均衡)
readonly CF_COLO_DEFAULT="TPE,HKG,NRT,HND,KIX,SIN,LAX,SJC,SEA,OKA,ICN,FRA"

# ip.txt 镜像源(依次降级): XIU2 库 = 官方公开段(ips-v4/ips-v6)拆分过滤后的
# 细分候选(/24粒度), 直接拉官方粗段(/13 /14)会被 cfst 展开成上百万 IP 不可用
ip_list_mirrors() {
    echo "https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/%s.txt"
    echo "https://raw.gitmirror.com/XIU2/CloudflareSpeedTest/master/%s.txt"
    echo "https://ghproxy.net/https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/%s.txt"
}

# 按 IP 版本返回对应候选列表文件路径
ip_list_file() {
    local ip_version="$1"
    [[ "$ip_version" == "ipv6" ]] && echo "$IP_DIR/ipv6.txt" || echo "$IP_DIR/ip.txt"
}

# 返回列表文件最后修改距今的天数(统计信息缺失时返回 0)
ip_list_age_days() {
    local f="$1" mtime now
    mtime=$(stat -c %Y "$f" 2>/dev/null)
    [[ "$mtime" =~ ^[0-9]+$ ]] || { echo "0"; return 0; }
    now=$(date +%s)
    echo $(( (now - mtime) / 86400 ))
}

# 在线更新 IP 候选列表: 依次尝试镜像源, 成功即替换
ip_list_update() {
    local ip_version f template
    ip_version=$(json_get '.ip_version')
    f=$(ip_list_file "$ip_version")
    mkdir -p "$IP_DIR"

    info "更新 IP 列表: $f"
    local fetched=0
    template=$(ip_list_mirrors | head -n1)
    local url
    while IFS= read -r url; do
        url=$(printf "$url" "$ip_version")
        info "尝试: $url"
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$f.tmp" "$url" 2>/dev/null && [[ -s "$f.tmp" ]]; then
            mv "$f.tmp" "$f"
            fetched=1
            info "IP 列表更新完成 ($(wc -l < "$f") 条候选)"
            break
        fi
        rm -f "$f.tmp"
    done <<< "$(ip_list_mirrors)"

    [[ "$fetched" -eq 1 ]] || warn "IP 列表更新失败，保留原列表"
}

# 测速前检查列表年龄, 超过 max_age_days 自动刷新(受 ip_list.auto_update 开关控制)
ip_list_refresh_if_stale() {
    local auto_update max_age ip_version f
    auto_update=$(json_get '.ip_list.auto_update')
    [[ "$auto_update" == "true" ]] || return 0

    ip_version=$(json_get '.ip_version')
    f=$(ip_list_file "$ip_version")
    [[ -f "$f" ]] || { ip_list_update; return 0; }

    max_age=$(json_get '.ip_list.max_age_days')
    if (( $(ip_list_age_days "$f") >= max_age )); then
        info "IP 列表已 ${max_age} 天未更新，自动刷新"
        ip_list_update
    else
        info "IP 列表 $(ip_list_age_days "$f") 天前更新，无需刷新"
    fi
}

# 测速前置检查: 列表/二进制可达性 + 所需命令齐全
ip_test_prepare() {
    local ip_version
    ip_version=$(json_get '.ip_version')

    ip_list_refresh_if_stale

    if [[ "$ip_version" == "ipv6" ]]; then
        [[ -f "$IP_DIR/ipv6.txt" ]] || die "缺少 IPv6 IP 列表: $IP_DIR/ipv6.txt"
        IP_LIST="$IP_DIR/ipv6.txt"
    else
        [[ -f "$IP_DIR/ip.txt" ]] || die "缺少 IPv4 IP 列表: $IP_DIR/ip.txt"
        IP_LIST="$IP_DIR/ip.txt"
    fi

    [[ -x "$CFST_BIN" ]] || die "cfst 不存在或不可执行: $CFST_BIN"
    require_cmd awk sed
}

# 核心测速: 从 config 读取全部 cfst 参数 -> 组装命令行 -> 执行 -> 校验结果
# 结果截断规则在文件尾段: 全 0 速度/缺行时按候选数对齐, 保证 result.csv 行数可靠
ip_test_run() {
    # ---- 读取并清洗配置(非法值回退默认, 防止命令注入/损坏的 json 传参) ----
    ip_test_prepare

    local port speed_test_enabled speed_test_url speed_test_threads speed_test_display
    local speed_test_latency_max speed_test_latency_min speed_test_speed_min
    local speed_test_test_times speed_test_download_timeout speed_test_display_results speed_test_loss_max
    local speed_test_httping speed_test_httping_code speed_test_debug speed_test_allip
    port=$(json_get '.port')
    speed_test_enabled=$(json_get '.speed_test.enabled')
    speed_test_url=$(json_get '.speed_test.url')
    speed_test_threads=$(json_get '.speed_test.threads')
    speed_test_display=$(json_get '.speed_test.display_count')
    speed_test_latency_max=$(json_get '.speed_test.avg_latency_max')
    speed_test_latency_min=$(json_get '.speed_test.avg_latency_min')
    speed_test_speed_min=$(json_get '.speed_test.download_speed_min')
    speed_test_test_times=$(json_get '.speed_test.test_times')
    speed_test_download_timeout=$(json_get '.speed_test.download_timeout')
    speed_test_display_results=$(json_get '.speed_test.display_results')
    speed_test_loss_max=$(json_get '.speed_test.packet_loss_max')
    speed_test_httping=$(json_get '.speed_test.httping')
    speed_test_httping_code=$(json_get '.speed_test.httping_code')
    speed_test_debug=$(json_get '.speed_test.debug')
    speed_test_allip=$(json_get '.speed_test.allip')
    [[ "$speed_test_test_times" =~ ^[0-9]+$ && "$speed_test_test_times" -ge 1 ]] || speed_test_test_times=4
    [[ "$speed_test_download_timeout" =~ ^[0-9]+$ && "$speed_test_download_timeout" -ge 3 ]] || speed_test_download_timeout=15
    [[ "$speed_test_display_results" =~ ^[0-9]+$ ]] || speed_test_display_results=10
    [[ "$speed_test_loss_max" =~ ^[0-9.]+$ ]] || speed_test_loss_max=1.00
    [[ "$speed_test_httping" =~ ^(true|false)$ ]] || speed_test_httping=false
    [[ "$speed_test_httping_code" =~ ^[0-9]{3}$ ]] || speed_test_httping_code=200
    [[ "$speed_test_debug" =~ ^(true|false)$ ]] || speed_test_debug=false
    [[ "$speed_test_allip" =~ ^(true|false)$ ]] || speed_test_allip=false

    local ip_version
    ip_version=$(json_get '.ip_version')

    # 候选数 = max(显示数, 解析池目标数), 保证池能增量填充到目标
    local cand_num
    cand_num=$(json_get '.cloudflare.min_records')
    [[ "$cand_num" =~ ^[0-9]+$ ]] || cand_num=0
    (( cand_num < speed_test_display )) && cand_num=$speed_test_display
    (( cand_num < 1 )) && cand_num=1
    (( cand_num > 100 )) && cand_num=100

    local cfst_args=()
    cfst_args+=("-tp" "$port")
    cfst_args+=("-t" "$speed_test_test_times")
    cfst_args+=("-n" "$speed_test_threads")
    cfst_args+=("-dn" "$cand_num")
    cfst_args+=("-p" "$speed_test_display_results")
    cfst_args+=("-tl" "$speed_test_latency_max")
    cfst_args+=("-tll" "$speed_test_latency_min")
    cfst_args+=("-tlr" "$speed_test_loss_max")
    cfst_args+=("-sl" "$speed_test_speed_min")
    cfst_args+=("-dt" "$speed_test_download_timeout")
    cfst_args+=("-f" "$IP_LIST")

    if [[ "$speed_test_enabled" == "true" ]]; then
        local url proto
        # 端口决定协议(CF 商用端口走 https, 其余走 http); url 为空则用官方端点兜底
        [[ "$port" =~ ^(443|8443|2053|2083|2087|2096)$ ]] && proto="https://" || proto="http://"
        if [[ -n "$speed_test_url" ]]; then
            [[ "$speed_test_url" =~ ^https?:// ]] && url="$speed_test_url" || url="${proto}${speed_test_url}"
        else
            url="${proto}speed.cloudflare.com/__down?bytes=200000000"
        fi
        cfst_args+=("-url" "$url")
        # 记录本轮测速源(供通知展示): 官方端点 / 配置地址, 按 URL 内容自动判别
        local url_label="配置地址"
        [[ "$url" == *"speed.cloudflare.com"* ]] && url_label="官方端点"
        echo "$url|$url_label" > "$SPEED_URL_FILE"
    else
        cfst_args+=("-dd")
        : > "$SPEED_URL_FILE"
    fi

    if [[ "$ip_version" == "ipv4" ]]; then
        local colo
        colo=$(json_get '.speed_test.colo')
        if [[ -z "$colo" ]]; then
            colo="$CF_COLO_DEFAULT"
        fi
        cfst_args+=("-cfcolo" "$colo")
    fi

    if [[ "$speed_test_httping" == "true" ]]; then
        cfst_args+=("-httping")
        cfst_args+=("-httping-code" "$speed_test_httping_code")
    fi
    [[ "$speed_test_debug" == "true" ]] && cfst_args+=("-debug")
    [[ "$speed_test_allip" == "true" ]] && cfst_args+=("-allip")

    info "开始测速: ${cfst_args[*]}"
    ( cd "$ROOT_DIR" && "$CFST_BIN" "${cfst_args[@]}" )

    [[ -f "$ROOT_DIR/result.csv" ]] || die "测速失败，未生成 result.csv"

    local second_line
    second_line=$(sed -n '2p' "$ROOT_DIR/result.csv" | tr -d '[:space:]')
    [[ -n "$second_line" ]] || die "测速结果为空，请尝试更换端口或重试"

    local speed_zero
    speed_zero=$(awk -F, 'NR==2 {print $6}' "$ROOT_DIR/result.csv")
    if [[ "$speed_zero" == "0.00" ]]; then
        awk -F, -v k=$(( cand_num + 2 )) 'NR==1 || NR<=k {print}' "$ROOT_DIR/result.csv" > "$ROOT_DIR/new_result.csv"
        mv "$ROOT_DIR/new_result.csv" "$ROOT_DIR/result.csv"
    fi

    if [[ $(awk -F, -v r=$(( cand_num + 2 )) 'NR==r {print $1}' "$ROOT_DIR/result.csv" 2>/dev/null) ]]; then
        awk -F, -v k=$(( cand_num + 1 )) 'NR==1 || NR<=k {print}' "$ROOT_DIR/result.csv" > "$ROOT_DIR/new_result.csv"
        mv "$ROOT_DIR/new_result.csv" "$ROOT_DIR/result.csv"
    fi

    info "测速完成，结果保存至 $ROOT_DIR/result.csv"
}

# 从 result.csv 取出全部候选 IP (供 DNS 更新使用)
ip_test_get_ips() {
    [[ -f "$ROOT_DIR/result.csv" ]] || die "结果文件不存在"
    awk -F, 'NR > 1 {print $1}' "$ROOT_DIR/result.csv"
}

# 打印测速结果摘要(供 status/菜单查看, 条目数受 display_count 限制)
ip_test_get_info() {
    [[ -f "$ROOT_DIR/result.csv" ]] || die "结果文件不存在"
    awk -F, 'NR > 1 {printf "IP: %-40s 延迟: %-8s 下载: %-8s\n", $1, $4, $6}' "$ROOT_DIR/result.csv" | head -n "$(json_get '.speed_test.display_count')"
}