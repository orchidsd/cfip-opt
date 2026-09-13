#!/bin/bash
# ============================================================================
# 配置管理模块
#   - config_init/validate/show: 保证 config.json 存在且键齐全, 验证关键字段非空
#   - config_interactive: 分组交互向导(基本/账号/测速/高级/验证/通知)
#   - 单独分组函数(config_edit_basic/account/...): 每组独立调用, 合并保存
#   - config_change_client: 独立切换代理客户端枚举
#   - 公共问答助手(cfg_ask/cfg_ask_map/cfg_ask_num/cfg_ask_req/cfg_ask_bool):
#     带当前值回车保留、q取消、EOF安全、枚举行内展示
# ============================================================================
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

config_init() {
    [[ -f "$CONFIG_FILE" ]] || {
        cp "$CONF_DIR/config.json.example" "$CONFIG_FILE"
        info "已创建默认配置文件: $CONFIG_FILE"
        info "请编辑配置文件后再运行"
        exit 0
    }
    require_cmd jq
    info "配置文件加载成功"
}

config_validate() {
    local mode email zone_id api_key domain subdomain port
    mode=$(json_get '.mode')
    email=$(json_get '.cloudflare.email')
    zone_id=$(json_get '.cloudflare.zone_id')
    api_key=$(json_get '.cloudflare.api_key')
    domain=$(json_get '.cloudflare.domain')
    subdomain=$(json_get '.cloudflare.subdomain')
    port=$(json_get '.port')

    [[ "$mode" =~ ^(domain|ip)$ ]] || die "mode 必须是 domain 或 ip"
    [[ "$port" =~ ^(80|8080|8880|2052|2082|2086|2095|443|8443|2053|2083|2087|2096)$ ]] || die "端口无效: $port"

    if [[ "$mode" == "domain" ]]; then
        [[ -n "$email" && -n "$zone_id" && -n "$api_key" ]] || die "域名模式需要配置 Cloudflare 邮箱、Zone ID、API Key"

        local strategy
        strategy=$(json_get '.cloudflare.strategy')
        [[ "$strategy" =~ ^(multi_to_one|one_to_one)$ ]] || die "cloudflare.strategy 必须是 multi_to_one 或 one_to_one"

        if [[ "$strategy" == "multi_to_one" ]]; then
            [[ -n "$domain" && -n "$subdomain" ]] || die "multi_to_one 需要配置主域名和子域名"
            is_valid_domain "$domain" || die "主域名格式无效: $domain"

            local keep_days max_records min_records node_domains
            keep_days=$(json_get '.cloudflare.keep_days')
            max_records=$(json_get '.cloudflare.max_records')
            min_records=$(json_get '.cloudflare.min_records')
            node_domains=$(json_get '.cloudflare.node_domains')
            [[ "$keep_days" =~ ^[0-9]+$ && "$keep_days" -le 30 ]] || die "cloudflare.keep_days 范围 0-30 (0=每次全清)"
            [[ "$max_records" =~ ^[0-9]+$ && "$max_records" -ge 1 && "$max_records" -le 100 ]] || die "cloudflare.max_records 范围 1-100"
            [[ "$min_records" =~ ^[0-9]+$ && "$min_records" -ge 1 && "$min_records" -le "$max_records" ]] || die "cloudflare.min_records 范围 1-$max_records"
            if [[ -n "$node_domains" ]]; then
                local nd
                for nd in ${node_domains//,/ }; do
                    is_valid_domain "$nd" || die "cloudflare.node_domains 含无效域名: $nd"
                done
            fi
        else
            local hostname
            hostname=$(json_get '.cloudflare.hostname')
            [[ -n "$hostname" ]] || die "one_to_one 需要配置域名列表 (cloudflare.hostname)"
        fi
    fi

    local ip_version
    ip_version=$(json_get '.ip_version')
    [[ "$ip_version" =~ ^(ipv4|ipv6)$ ]] || die "ip_version 必须是 ipv4 或 ipv6"

    local st_enabled st_threads st_display st_colo
    local st_test_times st_download_timeout st_display_results st_loss_max
    local st_httping st_httping_code st_debug st_allip
    st_enabled=$(json_get '.speed_test.enabled')
    st_threads=$(json_get '.speed_test.threads')
    st_display=$(json_get '.speed_test.display_count')
    st_colo=$(json_get '.speed_test.colo')
    st_test_times=$(json_get '.speed_test.test_times')
    st_download_timeout=$(json_get '.speed_test.download_timeout')
    st_display_results=$(json_get '.speed_test.display_results')
    st_loss_max=$(json_get '.speed_test.packet_loss_max')
    [[ "$st_enabled" =~ ^(true|false)$ ]] || die "speed_test.enabled 必须是 true 或 false"
    [[ "$st_threads" -gt 0 && "$st_threads" -le 1000 ]] || die "speed_test.threads 范围 1-1000"
    [[ "$st_display" -gt 0 && "$st_display" -le 100 ]] || die "speed_test.display_count 范围 1-100"
    if [[ -n "$st_colo" ]]; then
        [[ "$st_colo" =~ ^[A-Z]{3,4}(,[A-Z]{3,4})*$ ]] || die "speed_test.colo 格式错误，示例: TPE,HKG,NRT"
    fi
    [[ "$st_test_times" =~ ^[0-9]+$ && "$st_test_times" -ge 1 && "$st_test_times" -le 20 ]] || die "speed_test.test_times 范围 1-20"
    [[ "$st_download_timeout" =~ ^[0-9]+$ && "$st_download_timeout" -ge 3 && "$st_download_timeout" -le 60 ]] || die "speed_test.download_timeout 范围 3-60"
    [[ "$st_display_results" =~ ^[0-9]+$ && "$st_display_results" -ge 0 && "$st_display_results" -le 100 ]] || die "speed_test.display_results 范围 0-100"
    [[ "$st_loss_max" =~ ^(0([.][0-9]{1,2})?|1([.]0{1,2})?)$ ]] || die "speed_test.packet_loss_max 范围 0.00-1.00"

    st_httping=$(json_get '.speed_test.httping')
    st_httping_code=$(json_get '.speed_test.httping_code')
    st_debug=$(json_get '.speed_test.debug')
    st_allip=$(json_get '.speed_test.allip')
    [[ "$st_httping" =~ ^(true|false)$ ]] || die "speed_test.httping 必须是 true 或 false"
    [[ "$st_httping_code" =~ ^[0-9]{3}$ ]] || die "speed_test.httping_code 必须是三位数字"
    [[ "$st_debug" =~ ^(true|false)$ ]] || die "speed_test.debug 必须是 true 或 false"
    [[ "$st_allip" =~ ^(true|false)$ ]] || die "speed_test.allip 必须是 true 或 false"

    local v_enabled v_max v_probes
    v_enabled=$(json_get '.verify.enabled')
    v_max=$(json_get '.verify.max_ms')
    v_probes=$(json_get '.verify.probes')
    [[ "$v_enabled" =~ ^(true|false)$ ]] || die "verify.enabled 必须是 true 或 false"
    [[ "$v_max" =~ ^[0-9]+$ && "$v_max" -ge 10 ]] || die "verify.max_ms 必须是 ≥10 的数字"
    [[ "$v_probes" =~ ^[0-9]+$ && "$v_probes" -ge 1 && "$v_probes" -le 10 ]] || die "verify.probes 范围 1-10"

    local wd_enabled wd_auto wd_fail
    wd_enabled=$(json_get '.watchdog.enabled')
    wd_auto=$(json_get '.watchdog.auto_run')
    wd_fail=$(json_get '.watchdog.fail_consecutive')
    [[ "$wd_enabled" =~ ^(true|false)$ ]] || die "watchdog.enabled 必须是 true 或 false"
    [[ "$wd_auto" =~ ^(true|false)$ ]] || die "watchdog.auto_run 必须是 true 或 false"
    [[ "$wd_fail" =~ ^[0-9]+$ && "$wd_fail" -ge 1 && "$wd_fail" -le 12 ]] || die "watchdog.fail_consecutive 范围 1-12"

    local il_auto il_age
    il_auto=$(json_get '.ip_list.auto_update')
    il_age=$(json_get '.ip_list.max_age_days')
    [[ "$il_auto" =~ ^(true|false)$ ]] || die "ip_list.auto_update 必须是 true 或 false"
    [[ "$il_age" =~ ^[0-9]+$ && "$il_age" -ge 1 && "$il_age" -le 60 ]] || die "ip_list.max_age_days 范围 1-60"

    local proxy_client
    proxy_client=$(json_get '.proxy_client')
    [[ "$proxy_client" =~ ^(passwall|passwall2|shadowsocksr|clash|openclash|bypass|v2raya|hello-world|homeproxy|mihomo|shellcrash|none)$ ]] || die "proxy_client 值无效"

    local tg_enabled tg_token tg_user_id
    tg_enabled=$(json_get '.notifications.telegram.enabled')
    tg_token=$(json_get '.notifications.telegram.bot_token')
    tg_user_id=$(json_get '.notifications.telegram.user_id')
    [[ "$tg_enabled" =~ ^(true|false)$ ]] || die "telegram.enabled 必须是 true 或 false"
    [[ "$tg_enabled" == "true" && -z "$tg_token" ]] && die "启用 Telegram 需要配置 bot_token"
    [[ "$tg_enabled" == "true" && -z "$tg_user_id" ]] && die "启用 Telegram 需要配置 user_id"

    local pp_enabled pp_token
    pp_enabled=$(json_get '.notifications.pushplus.enabled')
    pp_token=$(json_get '.notifications.pushplus.token')
    [[ "$pp_enabled" =~ ^(true|false)$ ]] || die "pushplus.enabled 必须是 true 或 false"
    [[ "$pp_enabled" == "true" && -z "$pp_token" ]] && die "启用 PushPlus 需要配置 token"

    info "配置校验通过"
}

config_show() {
    echo "=== 当前配置 ==="
    jq . "$CONFIG_FILE"
}

# ==================== 配置交互模块 ====================
# 通用问答助手: 供各分组编辑函数复用, 返回 1 表示用户取消(q)

cfg_ask() {
    # 自由文本, 回车保留当前值
    local v
    read -rp "$1" v
    [[ "$v" == "q" || "$v" == "Q" ]] && return 1
    echo "${v:-$2}"
    return 0
}

cfg_ask_bool() {
    # 布尔开关: 1=是 0=否, 回车保留当前值
    local label cur v; label=$1; cur=$2
    while :; do
        read -rp "  $label [1]是 [0]否 (回车=$cur, q=取消): " v
        [[ -z "$v" ]] && { echo "$cur"; return 0; }
        case "$v" in
            q|Q) echo "$cur"; return 1 ;;
            1|y|Y|true) echo true; return 0 ;;
            0|n|N|false) echo false; return 0 ;;
        esac
        echo "    请输入 1 或 0"
    done
}

cfg_ask_map() {
    # 枚举选择: 传 "1=值" "2=值" ..., 输入数字
    local label cur v p part; label=$1; cur=$2; shift 2
    while :; do
        read -rp "  $label (${*}, 回车=$cur, q=取消): " v
        [[ -z "$v" ]] && { echo "$cur"; return 0; }
        [[ "$v" == "q" || "$v" == "Q" ]] && { echo "$cur"; return 1; }
        for p in "$@"; do
            part=${p%%=*}
            [[ "$v" == "$part" ]] && { echo "${p#*=}"; return 0; }
        done
        echo "    请输入数字选项"
    done
}

cfg_ask_num() {
    # 数字输入, 回车保留当前值
    local label cur v; label=$1; cur=$2
    while :; do
        read -rp "  $label [当前 $cur] (回车保留, q=取消): " v
        [[ -z "$v" ]] && { echo "$cur"; return 0; }
        [[ "$v" == "q" || "$v" == "Q" ]] && { echo "$cur"; return 1; }
        [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && { echo "$v"; return 0; }
        echo "    请输入数字"
    done
}

cfg_ask_req() {
    # 必填文本, 不能为空; Ctrl-D/EOF 视为取消返回
    local label cur v; label=$1; cur=$2
    while :; do
        read -rp "  $label [${cur:-未设置}] (回车保留, q=取消): " v || { echo "$cur"; return 1; }
        [[ "$v" == "q" || "$v" == "Q" ]] && { echo "$cur"; return 1; }
        [[ -z "$v" ]] && v=$cur
        [[ -n "$v" ]] && { echo "$v"; return 0; }
        echo "    此项不能为空"
    done
}

cfg_save_confirm() {
    # 各组末尾的确认保存, 返回 1 表示取消
    local v
    read -rp "  确认保存？ [1]保存 [0]取消: " v
    if [[ "$v" =~ ^[1yY]$ ]]; then
        return 0
    fi
    info "已取消，未做任何修改"
    return 1
}

# 仅更换代理客户端 (独立入口, 独立保存)
config_change_client() {
    echo "==================== 代理客户端 ===================="
    local proxy_client
    while :; do
        proxy_client=$(cfg_ask_map "代理客户端" "$(json_get '.proxy_client')" \
            "1=openclash" "2=passwall" "3=passwall2" "4=clash" \
            "5=mihomo" "6=shadowsocksr" "7=v2raya" "8=none" \
            "9=其他(手动输入)") || { echo "已取消"; return 0; }
        [[ "$proxy_client" != "其他(手动输入)" ]] && break
        proxy_client=$(cfg_ask "客户端名称 (如 homeproxy): ") || { echo "已取消"; return 0; }
        [[ -n "$proxy_client" ]] && break
        echo "    不能为空"
    done
    json_set '.proxy_client' "$proxy_client"
    info "代理客户端已设为: $proxy_client"
}

# 分组 1: 基本设置 (模式 / IP版本 / 端口)
config_edit_basic() {
    echo "==================== 基本设置 ===================="
    local mode ip_version port
    mode=$(cfg_ask_map "模式" "$(json_get '.mode')" "1=domain" "2=ip") || return 0
    ip_version=$(cfg_ask_map "IP 版本" "$(json_get '.ip_version')" "1=ipv4" "2=ipv6") || return 0
    port=$(cfg_ask_num "端口 (常用 443/80/8443)" "$(json_get '.port')") || return 0
    echo
    cfg_save_confirm || return 1
    json_set '.mode' "$mode"
    json_set '.ip_version' "$ip_version"
    json_set '.port' "$port"
    info "基本设置已保存"
}

# 分组 2: Cloudflare 账号与解析池 (邮箱/Key/ZoneID/域名/池大小)
config_edit_account() {
    echo "============= Cloudflare 账号与解析池 ============="
    local email zone_id api_key strategy domain subdomain
    local cf_keep_days cf_max_records cf_min_records cf_hostname cf_node_domains
    email=$(cfg_ask_req "登录邮箱" "$(json_get '.cloudflare.email')") || return 0
    zone_id=$(cfg_ask_req "Zone ID" "$(json_get '.cloudflare.zone_id')") || return 0
    api_key=$(cfg_ask_req "Global API Key" "$(json_get '.cloudflare.api_key')") || return 0
    strategy=$(cfg_ask_map "策略" "$(json_get '.cloudflare.strategy')" "1=multi_to_one" "2=one_to_one") || return 0

    if [[ "$strategy" == "multi_to_one" ]]; then
        domain=$(cfg_ask_req "主域名 (如 example.com)" "$(json_get '.cloudflare.domain')") || return 0
        subdomain=$(cfg_ask "子域名 [$(json_get '.cloudflare.subdomain')]: " "$(json_get '.cloudflare.subdomain')") || return 0
        cf_node_domains=$(cfg_ask "业务节点域名 (逗号分隔, 回车用子域名探测) [$(json_get '.cloudflare.node_domains')]: " "$(json_get '.cloudflare.node_domains')") || return 0
        cf_keep_days=$(cfg_ask_num "IP 保留天数 (0=每次全清)" "$(json_get '.cloudflare.keep_days')") || return 0
        if [[ "$(json_get '.cloudflare.max_records')" == "$(json_get '.cloudflare.min_records')" ]]; then
            cf_min_records=$(cfg_ask_num "解析池条数 (固定, 如 5)" "$(json_get '.cloudflare.max_records')") || return 0
            cf_max_records="$cf_min_records"
        else
            cf_min_records=$(cfg_ask_num "解析池目标条数" "$(json_get '.cloudflare.min_records')") || return 0
            cf_max_records=$(cfg_ask_num "解析池上限条数" "$(json_get '.cloudflare.max_records')") || return 0
        fi
    else
        cf_hostname=$(cfg_ask_req "域名列表 (空格分隔)" "$(json_get '.cloudflare.hostname')") || return 0
    fi
    echo
    cfg_save_confirm || return 1
    json_set '.cloudflare.email' "$email"
    json_set '.cloudflare.zone_id' "$zone_id"
    json_set '.cloudflare.api_key' "$api_key"
    json_set '.cloudflare.strategy' "$strategy"
    if [[ "$strategy" == "multi_to_one" ]]; then
        json_set '.cloudflare.domain' "$domain"
        json_set '.cloudflare.subdomain' "$subdomain"
        json_set '.cloudflare.keep_days' "$cf_keep_days"
        json_set '.cloudflare.max_records' "$cf_max_records"
        json_set '.cloudflare.min_records' "$cf_min_records"
        json_set '.cloudflare.node_domains' "$cf_node_domains"
    else
        json_set '.cloudflare.hostname' "$cf_hostname"
    fi
    info "账号与解析池已保存"
}

# 分组 3: 测速设置 (开关/线程/延迟/丢包/速度下限/地址/机场/HTTPing)
config_edit_speed() {
    echo "==================== 测速设置 ===================="
    local st_enabled st_threads st_display st_lat_max st_loss_max st_speed_min st_url st_colo st_httping
    st_enabled=$(cfg_ask_bool "启用下载测速" "$(json_get '.speed_test.enabled')") || return 0
    if [[ "$st_enabled" == "true" ]]; then
        st_threads=$(cfg_ask_num "线程数 (1-1000)" "$(json_get '.speed_test.threads')") || return 0
        st_display=$(cfg_ask_num "显示 IP 数量" "$(json_get '.speed_test.display_count')") || return 0
        st_lat_max=$(cfg_ask_num "平均延迟上限 (ms)" "$(json_get '.speed_test.avg_latency_max')") || return 0
        st_loss_max=$(cfg_ask_num "丢包率上限 (0.00-1.00)" "$(json_get '.speed_test.packet_loss_max')") || return 0
        st_speed_min=$(cfg_ask_num "下载速度下限 (MB/s, 0=不限)" "$(json_get '.speed_test.download_speed_min')") || return 0
        st_url=$(cfg_ask "测速地址 [$(json_get '.speed_test.url')]: " "$(json_get '.speed_test.url')") || return 0
        st_colo=$(cfg_ask "机场扫描 (逗号分隔, 回车默认) [$(json_get '.speed_test.colo')]: " "$(json_get '.speed_test.colo')") || return 0
    fi
    st_httping=$(cfg_ask_bool "延迟测速用 HTTP 协议" "$(json_get '.speed_test.httping')") || return 0
    echo
    cfg_save_confirm || return 1
    json_set '.speed_test.enabled' "$st_enabled"
    json_set '.speed_test.httping' "$st_httping"
    if [[ "$st_enabled" == "true" ]]; then
        json_set '.speed_test.threads' "$st_threads"
        json_set '.speed_test.display_count' "$st_display"
        json_set '.speed_test.avg_latency_max' "$st_lat_max"
        json_set '.speed_test.packet_loss_max' "$st_loss_max"
        json_set '.speed_test.download_speed_min' "$st_speed_min"
        json_set '.speed_test.url' "$st_url"
        json_set '.speed_test.colo' "$st_colo"
    fi
    info "测速设置已保存"
}

# 分组 4: 高级参数 (延时下限/次数/调试/下载限时/重启等待等低频项)
config_edit_adv() {
    echo "==================== 高级参数 ===================="
    local st_lat_min st_test_times st_download_timeout st_display_results
    local st_httping_code st_debug st_allip restart_wait_sec
    st_lat_min=$(cfg_ask_num "平均延迟下限 (ms)" "$(json_get '.speed_test.avg_latency_min')") || return 0
    st_test_times=$(cfg_ask_num "延迟测速次数" "$(json_get '.speed_test.test_times')") || return 0
    st_download_timeout=$(cfg_ask_num "单个 IP 下载限时 (s)" "$(json_get '.speed_test.download_timeout')") || return 0
    st_display_results=$(cfg_ask_num "控制台显示条数" "$(json_get '.speed_test.display_results')") || return 0
    st_httping_code=$(cfg_ask_num "HTTPing 有效状态码" "$(json_get '.speed_test.httping_code')") || return 0
    st_debug=$(cfg_ask_bool "调试输出 -debug" "$(json_get '.speed_test.debug')") || return 0
    st_allip=$(cfg_ask_bool "每段全部 IP -allip" "$(json_get '.speed_test.allip')") || return 0
    restart_wait_sec=$(cfg_ask_num "重启代理后等待 (s)" "$(json_get '.restart_wait_sec')") || return 0
    echo
    cfg_save_confirm || return 1
    json_set '.speed_test.avg_latency_min' "$st_lat_min"
    json_set '.speed_test.test_times' "$st_test_times"
    json_set '.speed_test.download_timeout' "$st_download_timeout"
    json_set '.speed_test.display_results' "$st_display_results"
    json_set '.speed_test.httping_code' "$st_httping_code"
    json_set '.speed_test.debug' "$st_debug"
    json_set '.speed_test.allip' "$st_allip"
    json_set '.restart_wait_sec' "$restart_wait_sec"
    info "高级参数已保存"
}

# 分组 5: 验证与自愈 (推送前验证 + 看门狗)
config_edit_verify() {
    echo "==================== 验证与自愈 ===================="
    local v_enabled v_max v_probes wd_enabled wd_auto wd_fail
    v_enabled=$(cfg_ask_bool "推送前验证" "$(json_get '.verify.enabled')") || return 0
    v_max=$(cfg_ask_num "验证响应阈值 (ms)" "$(json_get '.verify.max_ms')") || return 0
    v_probes=$(cfg_ask_num "每次探测次数" "$(json_get '.verify.probes')") || return 0
    wd_enabled=$(cfg_ask_bool "自愈看门狗" "$(json_get '.watchdog.enabled')") || return 0
    if [[ "$wd_enabled" == "true" ]]; then
        wd_auto=$(cfg_ask_bool "失败后自动重选 (否=仅通知)" "$(json_get '.watchdog.auto_run')") || return 0
        wd_fail=$(cfg_ask_num "连续失败几次触发" "$(json_get '.watchdog.fail_consecutive')") || return 0
    fi
    echo
    cfg_save_confirm || return 1
    json_set '.verify.enabled' "$v_enabled"
    json_set '.verify.max_ms' "$v_max"
    json_set '.verify.probes' "$v_probes"
    json_set '.watchdog.enabled' "$wd_enabled"
    json_set '.watchdog.auto_run' "$wd_auto"
    json_set '.watchdog.fail_consecutive' "$wd_fail"
    info "验证与自愈已保存"
}

# 分组 6: IP列表与通知 (自动更新 / Telegram / PushPlus)
config_edit_notify() {
    echo "================== IP列表与通知 ==================="
    local il_auto il_age tg_enabled tg_token tg_user_id tg_host pp_enabled pp_token
    il_auto=$(cfg_ask_bool "IP 列表自动更新" "$(json_get '.ip_list.auto_update')") || return 0
    il_age=$(cfg_ask_num "超过几天刷新列表" "$(json_get '.ip_list.max_age_days')") || return 0
    tg_enabled=$(cfg_ask_bool "启用 Telegram 通知" "$(json_get '.notifications.telegram.enabled')") || return 0
    if [[ "$tg_enabled" == "true" ]]; then
        tg_token=$(cfg_ask_req "Telegram Bot Token" "$(json_get '.notifications.telegram.bot_token')") || return 0
        tg_user_id=$(cfg_ask_req "Telegram User ID" "$(json_get '.notifications.telegram.user_id')") || return 0
        tg_host=$(cfg_ask "API Host (回车用官方)" "$(json_get '.notifications.telegram.api_host')") || return 0
    fi
    pp_enabled=$(cfg_ask_bool "启用 PushPlus 通知" "$(json_get '.notifications.pushplus.enabled')") || return 0
    if [[ "$pp_enabled" == "true" ]]; then
        pp_token=$(cfg_ask_req "PushPlus Token" "$(json_get '.notifications.pushplus.token')") || return 0
    fi
    echo
    cfg_save_confirm || return 1
    json_set '.ip_list.auto_update' "$il_auto"
    json_set '.ip_list.max_age_days' "$il_age"
    json_set '.notifications.telegram.enabled' "$tg_enabled"
    [[ "$tg_enabled" == "true" ]] && {
        json_set '.notifications.telegram.bot_token' "$tg_token"
        json_set '.notifications.telegram.user_id' "$tg_user_id"
        json_set '.notifications.telegram.api_host' "$tg_host"
    }
    json_set '.notifications.pushplus.enabled' "$pp_enabled"
    [[ "$pp_enabled" == "true" ]] && json_set '.notifications.pushplus.token' "$pp_token"
    info "IP列表与通知已保存"
}

# 全量入口: 依次走完所有分组 (对应子命令 cfip-opt.sh config)
config_interactive() {
    config_edit_basic || return 0; echo
    config_edit_account || return 0; echo
    config_edit_speed || return 0; echo
    config_edit_adv || return 0; echo
    config_edit_verify || return 0; echo
    config_edit_notify || return 0
}
