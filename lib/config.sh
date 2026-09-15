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
# 库路径: 优先用调用方已定义好的 LIB_DIR(绝对路径); 未定义时按本文件自定位
: "${LIB_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"
source "$LIB_DIR/common.sh"

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

    local st_lat_max st_lat_min st_speed_min
    st_lat_max=$(json_get '.speed_test.avg_latency_max')
    st_lat_min=$(json_get '.speed_test.avg_latency_min')
    st_speed_min=$(json_get '.speed_test.download_speed_min')
    [[ "$st_lat_max" =~ ^[0-9]+$ && "$st_lat_max" -ge 0 ]] || die "speed_test.avg_latency_max 必须是非负整数"
    [[ "$st_lat_min" =~ ^[0-9]+$ && "$st_lat_min" -ge 0 ]] || die "speed_test.avg_latency_min 必须是非负整数"
    [[ "$st_speed_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "speed_test.download_speed_min 必须是非负数字"

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

    local pk_en pk_s pk_e
    pk_en=$(json_get '.peak_hours.enabled')
    [[ "$pk_en" =~ ^(true|false)$ ]] || die "peak_hours.enabled 必须是 true 或 false"
    pk_s=$(json_get '.peak_hours.start'); pk_e=$(json_get '.peak_hours.end')
    [[ "$pk_s" =~ ^[0-9]+$ && "$pk_s" -ge 0 && "$pk_s" -le 23 ]] || die "peak_hours.start 范围 0-23"
    [[ "$pk_e" =~ ^[0-9]+$ && "$pk_e" -ge 0 && "$pk_e" -le 23 ]] || die "peak_hours.end 范围 0-23"

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

# ==================== 分组编辑引擎 ====================
# 数字小菜单(仿主菜单): 逐项显示当前值, 输入数字单改该项即写盘, 可任意回退.
# 用法: cfg_group_edit "标题" "规格" "规格"...
# 规格 = "类型|json路径|描述|附加|条件" (描述内勿含 |)
#   类型: bool(1/0) num(数字) str(文本,回车保留) req(必填) opt(可清空,回车=当前,
#        附加填"留空提示") map(枚举, 附加="1=值;2=值")
#   条件: "父路径==期望值" 不满足则隐藏该行; "-" 表示无条件
_cfg_ask_field() {
    local type="$1" label="$2" cur="$3" extra="$4"
    case "$type" in
        bool) cfg_ask_bool "$label" "$cur" ;;
        num)  cfg_ask_num  "$label" "$cur" ;;
        req)  cfg_ask_req  "$label" "$cur" ;;
        str)  cfg_ask "  $label [当前: ${cur:-未设置}] (回车保留, q=取消): " "$cur" ;;
        opt)  cfg_ask_opt  "$label" "$cur" ;;
        map)
            # extra = "1=a;2=b", 拆成 cfg_ask_map 的多参
            local -a items=(); local it k v
            IFS=';' read -ra items <<< "$extra"
            local -a args=(); local item
            for item in "${items[@]}"; do
                IFS='=' read -r k v <<< "$item"
                args+=("$k=$v")
            done
            cfg_ask_map "$label" "$cur" "${args[@]}"
            ;;
    esac
}

cfg_group_edit() {
    local title="$1"; shift
    local -a specs=("$@")
    local -a ids=() meta=()
    local spec type jpath label extra cond cur
    local oldifs cj cv
    while :; do
        echo; echo "===== $title ====="
        ids=(); meta=()
        local n=0 i
        for spec in "${specs[@]}"; do
            oldifs=$IFS; IFS='|' read -r type jpath label extra cond <<< "$spec"; IFS=$oldifs
            [[ "$cond" == "-" ]] || {
                cj=${cond%%==*}; cv=${cond#*==}
                [[ "$(json_get "$cj" 2>/dev/null)" == "$cv" ]] || continue
            }
            n=$((n+1)); ids+=("$n"); meta+=("$spec")
            cur=$(json_get "$jpath" 2>/dev/null)
            printf '  %2d) %s  [%s]\n' "$n" "$label" "${cur:-空}"
        done
        echo '     0) 返回'
        read -rp "  输入数字修改该项 (回车=返回): " i
        [[ -z "$i" || "$i" == "0" ]] && { echo; return 0; }
        [[ "$i" =~ ^[0-9]+$ ]] || { echo '  无效输入'; continue; }
        local found=0
        for n in "${!ids[@]}"; do
            [[ "${ids[$n]}" == "$i" ]] || continue
            found=1
            oldifs=$IFS; IFS='|' read -r type jpath label extra cond <<< "${meta[$n]}"; IFS=$oldifs
            [[ "$cond" == "-" ]] || {
                cj=${cond%%==*}; cv=${cond#*==}
                [[ "$(json_get "$cj" 2>/dev/null)" == "$cv" ]] || { echo '  该项当前不可编辑(依赖未满足)'; break; }
            }
            local newv
            newv=$(_cfg_ask_field "$type" "$label" "$(json_get "$jpath")" "$extra") || break
            json_set "$jpath" "$newv"
            info "已保存: $label = $newv"
            break
        done
        [[ "$found" -eq 1 ]] || echo "  无效数字: $i"
    done
}

cfg_ask_opt() {
    # 可选项文本: 留空返回空串(表示交给上游用默认), 回车=空; q=取消
    local label cur v; label=$1; cur=$2
    read -rp "  $label [当前: ${cur:-空(官方端点)}] (回车=留空, q=取消): " v
    [[ "$v" == "q" || "$v" == "Q" ]] && return 1
    echo "$v"
    return 0
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
    cfg_group_edit "基本设置" \
        "map|.mode|模式|1=domain;2=ip|-" \
        "map|.ip_version|IP 版本|1=ipv4;2=ipv6|-" \
        "num|.port|端口 (常用 443/80/8443)||-"
}

# 分组 2: Cloudflare 账号与解析池 (邮箱/Key/ZoneID/域名/池大小)
config_edit_account() {
    cfg_group_edit "Cloudflare 账号与解析池" \
        "req|.cloudflare.email|登录邮箱||-" \
        "req|.cloudflare.zone_id|Zone ID||-" \
        "req|.cloudflare.api_key|Global API Key||-" \
        "map|.cloudflare.strategy|策略|1=multi_to_one;2=one_to_one|-" \
        "req|.cloudflare.domain|主域名 (如 example.com)||.cloudflare.strategy==multi_to_one" \
        "str|.cloudflare.subdomain|子域名||.cloudflare.strategy==multi_to_one" \
        "str|.cloudflare.node_domains|业务节点域名 (逗号分隔)||.cloudflare.strategy==multi_to_one" \
        "num|.cloudflare.keep_days|IP 保留天数 (0=每次全清)||.cloudflare.strategy==multi_to_one" \
        "num|.cloudflare.min_records|解析池目标条数 (min, 1-100)||.cloudflare.strategy==multi_to_one" \
        "num|.cloudflare.max_records|解析池上限条数 (max, ≥min)||.cloudflare.strategy==multi_to_one" \
        "req|.cloudflare.hostname|域名列表 (空格分隔)||.cloudflare.strategy==one_to_one"
}

# 分组 3: 测速设置 (开关/地址/线程/延迟阈值/丢包/下载/HTTPing/地区)
config_edit_speed() {
    cfg_group_edit "测速设置" \
        "bool|.speed_test.enabled|启用下载测速||-" \
        "opt|.speed_test.url|测速地址 (留空=官方端点)||-" \
        "num|.speed_test.threads|线程数 (1-1000)||-" \
        "num|.speed_test.test_times|延迟测速次数||-" \
        "num|.speed_test.avg_latency_max|平均延迟上限 (ms)||-" \
        "num|.speed_test.avg_latency_min|平均延迟下限 (ms)||-" \
        "num|.speed_test.packet_loss_max|丢包率上限 (0.00-1.00)||-" \
        "num|.speed_test.download_speed_min|下载速度下限 (MB/s, 0=不限)||.speed_test.enabled==true" \
        "num|.speed_test.display_count|下载测速 IP 数量||.speed_test.enabled==true" \
        "num|.speed_test.download_timeout|单个 IP 下载限时 (s)||.speed_test.enabled==true" \
        "bool|.speed_test.httping|延迟测速用 HTTP 协议||-" \
        "num|.speed_test.httping_code|HTTPing 有效状态码 (仅 HTTPing 生效)||-" \
        "str|.speed_test.colo|地区过滤 (仅 HTTPing+IPv4 生效)||-"
}

# 分组 4: 输出与调试 (显示条数/debug/allip/重启等待)
config_edit_adv() {
    cfg_group_edit "输出与调试" \
        "num|.speed_test.display_results|控制台显示条数||-" \
        "bool|.speed_test.debug|调试输出 -debug||-" \
        "bool|.speed_test.allip|每段全部 IP -allip||-" \
        "num|.restart_wait_sec|重启代理后等待 (s)||-"
}

# 分组 5: 验证与自愈 (推送前验证 + 看门狗)
config_edit_verify() {
    cfg_group_edit "验证与自愈" \
        "bool|.verify.enabled|推送前验证||-" \
        "num|.verify.max_ms|验证响应阈值 (ms)||-" \
        "num|.verify.probes|每次探测次数||-" \
        "bool|.watchdog.enabled|自愈看门狗||-" \
        "bool|.watchdog.auto_run|失败后自动重选 (否=仅通知)||.watchdog.enabled==true" \
        "num|.watchdog.fail_consecutive|连续失败几次触发||.watchdog.enabled==true"
}

# 分组 6: IP列表与通知 (自动更新 / Telegram / PushPlus)
config_edit_notify() {
    cfg_group_edit "IP列表与通知" \
        "bool|.ip_list.auto_update|IP 列表自动更新||-" \
        "num|.ip_list.max_age_days|超过几天刷新列表||-" \
        "bool|.notifications.telegram.enabled|启用 Telegram 通知||-" \
        "req|.notifications.telegram.bot_token|Telegram Bot Token||.notifications.telegram.enabled==true" \
        "req|.notifications.telegram.user_id|Telegram User ID||.notifications.telegram.enabled==true" \
        "str|.notifications.telegram.api_host|API Host (回车用官方)||.notifications.telegram.enabled==true" \
        "bool|.notifications.pushplus.enabled|启用 PushPlus 通知||-" \
        "req|.notifications.pushplus.token|PushPlus Token||.notifications.pushplus.enabled==true"
}

# ============ 定时任务组 (直接读写 crontab, 与本项目行幂等去重) ============
cron_run_line() { crontab -l 2>/dev/null | grep "cfip-opt\.sh run" | head -1; }
cron_wd_line()  { crontab -l 2>/dev/null | grep "watchdog\.sh"   | head -1; }
cron_hours_now() {
    local l; l=$(cron_run_line)
    [[ -n "$l" ]] && echo "$l" | awk '{print $2}' || echo "5,13,21"
}
cron_minute_now() {
    local l; l=$(cron_run_line)
    [[ -n "$l" ]] && echo "$l" | awk '{print $1}' || echo "0"
}
cron_wd_min_now() {
    local l; l=$(cron_wd_line)
    [[ -n "$l" ]] && echo "$l" | awk '{gsub(/[^0-9]/,"",$1); print ($1=="" ? 5 : $1)}' || echo "5"
}

# 分组 7: 定时任务 (优选时刻/看门狗间隔, 直接操作 crontab)
config_edit_cron() {
    echo "==================== 定时任务 ===================="
    echo "当前本项目定时任务:"
    crontab -l 2>/dev/null | grep -E 'cfip-opt\.sh run|watchdog\.sh' | sed 's/^/  /' || echo "  (无)"
    echo
    local RUN="$ROOT_DIR/bin/cfip-opt.sh run"
    local WD="$ROOT_DIR/bin/watchdog.sh"

    local st_auto_run st_hours st_minute st_wd st_wd_min
    st_auto_run=$(cfg_ask_bool "启用自动优选" "$(cron_run_line >/dev/null 2>&1 && echo true || echo false)") || return 0
    if [[ "$st_auto_run" == "true" ]]; then
        st_hours=$(cfg_ask "每日优选小时 (0-23, 逗号分隔可多个) [$(cron_hours_now)]: " "$(cron_hours_now)") || return 0
        st_hours=$(echo "$st_hours" | tr -d ' ')
        while ! [[ "$st_hours" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]]; do
            echo "    请输入 0-23 的数字或逗号分隔列表, 如 3,11,19"
            st_hours=$(cfg_ask "每日优选小时 (0-23, 逗号分隔可多个) [5,13,21]: " "5,13,21") || return 0
        done
        st_minute=$(cfg_ask_num "每日优选分钟 (0-59)" "$(cron_minute_now)") || return 0
    fi
    st_wd=$(cfg_ask_bool "启用看门狗自愈 (每N分钟)" "$(cron_wd_line >/dev/null 2>&1 && echo true || echo false)") || return 0
    if [[ "$st_wd" == "true" ]]; then
        st_wd_min=$(cfg_ask_num "看门狗间隔 (分钟)" "$(cron_wd_min_now)") || return 0
    fi

    echo
    cfg_save_confirm || return 1

    # 剔除旧的项目行(含已停用任务), 再按当前设置重写
    local newtab
    newtab=$(crontab -l 2>/dev/null | grep -vE 'cfip-opt\.sh run|watchdog\.sh')
    if [[ "$st_auto_run" == "true" ]]; then
        [[ -n "$newtab" ]] && newtab+=$'\n'
        newtab+="$st_minute $st_hours * * * $RUN"
    fi
    if [[ "$st_wd" == "true" ]]; then
        [[ -n "$newtab" ]] && newtab+=$'\n'
        newtab+="*/$st_wd_min * * * * $WD >/dev/null 2>&1"
    fi
    printf '%s\n' "$newtab" | crontab -
    info "定时任务已更新:"
    crontab -l 2>/dev/null | grep -E 'cfip-opt|watchdog' | sed 's/^/  /'
    info "定时任务设置已保存"
}

# 分组 8: 高峰跳过 (电信晚高峰时段跳过优选, 避免测出伪差结果)
config_edit_peak() {
    cfg_group_edit "高峰跳过" \
        "bool|.peak_hours.enabled|启用高峰时段跳过优选(晚高峰不测速)||-" \
        "num|.peak_hours.start|高峰开始小时 (0-23)||.peak_hours.enabled==true" \
        "num|.peak_hours.end|高峰结束小时 (0-23, 可跨午夜如 21→6)||.peak_hours.enabled==true"
}

# 全量入口: 依次走完所有分组 (对应子命令 cfip-opt.sh config)
config_interactive() {
    config_edit_basic || return 0; echo
    config_edit_account || return 0; echo
    config_edit_speed || return 0; echo
    config_edit_adv || return 0; echo
    config_edit_verify || return 0; echo
    config_edit_notify || return 0; echo
    config_edit_cron || return 0; echo
    config_edit_peak || return 0
}
