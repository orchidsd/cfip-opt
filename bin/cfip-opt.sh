#!/bin/bash
# ============================================================================
# Cloudflare 优选 IP - 主程序 (入口点)
#
# 流程: 测速抓取最快 Cloudflare IP -> 写入 Cloudflare DNS A 记录 -- 让
#       业务域名(如 cdn.xxx.eu.org)始终解析到最快边缘, 并驱动 OpenClash 等
#       代理客户端的节点延迟保持最优。
#
# 用法:
#   cfip            交互终端 -> 数字菜单 (推荐入口)
#   cfip run        完整优选流程 (cron 调用, 默认)
#   cfip config     交互式配置向导
#   cfip test/dns/status/notify/rollback/ipupdate  详见底部 usage
#
# 部署: bash bin/install.sh 一键安装 (任意 OpenWrt)
# 依赖: bash jq curl sed awk; 测速二进制 bin/cfst (CloudflareST)
# ============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly ROOT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LIB_DIR="$ROOT_DIR/lib"

# 按固定顺序装载各功能库(common 必须先于所有库)
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/ip_test.sh
source "$LIB_DIR/ip_test.sh"
# shellcheck source=lib/dns_update.sh
source "$LIB_DIR/dns_update.sh"
# shellcheck source=lib/notify.sh
source "$LIB_DIR/notify.sh"
# shellcheck source=lib/proxy.sh
source "$LIB_DIR/proxy.sh"

# 执行流程须在停代理(直连)状态下测速, 避免可用代理把延迟隐藏在隧道里
# 一键完整优选: 停代理 -> 测速抓优IP -> 更新DNS解析池 -> 重启代理 -> 推送通知
main() {
    config_init
    config_validate
    date +%s > "$RUN_START_FILE"

    > "$LOG_FILE"

    info "=== Cloudflare 优选 IP 启动 ==="
    config_show

    proxy_stop
    ip_test_run
    dns_update_main
    proxy_restart

    notify_all "$(notify_build_message)"

    local top_line top_lat top_speed
    top_line=$(sed -n '2p' "$ROOT_DIR/result.csv" 2>/dev/null)
    if [[ -n "$top_line" ]]; then
        top_lat=$(echo "$top_line" | awk -F, '{print $5}')
        top_speed=$(echo "$top_line" | awk -F, '{print $6}')
        [[ -n "$top_lat" && -n "$top_speed" ]] && echo "$top_lat,$top_speed" >> "$LAST_SUMMARY"
    fi

    info "=== 完成 ==="
    echo
    echo "切记：在软路由-计划任务中添加定时执行，例如每天 3 点："
    echo "0 3 * * * $ROOT_DIR/bin/cfip-opt.sh run"
}

# 仅测速: 与完整流程相同但不更新 DNS (调试/挑选用)
test_only() {
    config_init
    config_validate
    > "$LOG_FILE"
    info "=== 仅测速 (不更新 DNS) ==="
    proxy_stop
    ip_test_run
    ip_test_get_info
    proxy_restart
    info "=== 测速完成 ==="
}

# 运行状态面板: 代理/上次测速/DNS池/看门狗/定时任务
status() {
    config_init

    local svc client
    client=$(json_get '.proxy_client')
    svc=$(proxy_client_to_service "$client")
    printf '=%.0s' $(seq 1 52); echo
    echo "=== 运行状态 ==="
    if [[ -n "$svc" ]] && /etc/init.d/"$svc" status >/dev/null 2>&1; then
        echo "[代理] $svc: 运行中"
    else
        echo "[代理] $svc: 未运行"
    fi

    if [[ -f "$ROOT_DIR/result.csv" ]]; then
        local sec age_txt top
        sec=$(( $(date +%s) - $(date -r "$ROOT_DIR/result.csv" +%s 2>/dev/null || echo 0) ))
        if (( sec < 60 )); then age_txt="${sec}秒"; elif (( sec < 3600 )); then age_txt="$(( sec / 60 ))分钟"; else age_txt="$(( sec / 3600 ))小时"; fi
        top=$(awk -F, 'NR==2 {printf "%s 延迟%sms 吞吐%sMB/s %s", $1, $5, $6, $7}' "$ROOT_DIR/result.csv" 2>/dev/null)
        echo "[测速] $age_txt 前  最优: ${top:-暂无}"
    else
        echo "[测速] 尚无测速结果"
    fi

    if [[ "$(json_get '.mode')" == "domain" ]]; then
        local fqdn zone_id res cnt
        fqdn="$(json_get '.cloudflare.subdomain').$(json_get '.cloudflare.domain')"
        zone_id=$(json_get '.cloudflare.zone_id')
        if res=$(cf_request "GET" "${cf_api_base}/${zone_id}/dns_records?name=${fqdn}&type=A" 2>/dev/null); then
            cnt=$(echo "$res" | jq -r '[.result[]? | select((.content // "") != "")] | length // 0' 2>/dev/null)
            echo "[解析池] $fqdn 当前 $cnt 条 A 记录 (目标≥$(json_get '.cloudflare.min_records') 上限$(json_get '.cloudflare.max_records'))"
        else
            echo "[解析池] 实时查询失败 (网络/凭据)"
        fi
    fi

    if [[ -f "$WATCHDOG_LAST" ]]; then
        local last
        last=$(date -d "@$(cat "$WATCHDOG_LAST" 2>/dev/null)" '+%m-%d %H:%M' 2>/dev/null || echo "未知")
        echo "[看门狗] 上次自检: $last  (连续失败: $(cat "$WATCHDOG_FAIL" 2>/dev/null || echo 0))"
    else
        echo "[看门狗] 还没有自检记录"
    fi

    echo "[定时任务]"
    crontab -l 2>/dev/null | grep -E 'cfip-opt|watchdog' | sed 's/^/  /' || echo "  (无相关任务, 建议: 0 3 * * * $ROOT_DIR/bin/cfip-opt.sh run)"
    printf '=%.0s' $(seq 1 52); echo
}

# 主菜单: 数字选择, 回车返回菜单 / 退出; 配置类菜单项逐个直达对应分组
menu() {
    local choice
    local title pad bw_hr
    local C_GRN C_CYN C_YEL C_RED C_DIM C_RST W
    C_GRN=$'\033[32m'; C_CYN=$'\033[36m'; C_YEL=$'\033[33m'
    C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
    W=46
    title="Cloudflare 优选 IP 一键管理"
    pad=10
    bw_hr=$(printf '═%.0s' $(seq 1 "$W"))

    while true; do
        clear
        printf "${C_CYN}${bw_hr}${C_RST}\n"
        printf "${C_CYN}   ☁  ${C_YEL}%*s${C_CYN}\n" "$pad" "$title"
        printf "${C_CYN}${bw_hr}${C_RST}\n\n"
        local client
        client=$(json_get '.proxy_client')
        echo "  ${C_DIM}---- 主操作 ----${C_RST}"
        echo "  ${C_GRN}1${C_RST}. 一键完整优选   ${C_DIM}测速 + 更新DNS + 通知${C_RST}"
        echo "  ${C_GRN}2${C_RST}. 仅测速         ${C_DIM}不更新 DNS${C_RST}"
        echo "  ${C_GRN}3${C_RST}. 仅更新 DNS     ${C_DIM}用上次测速结果${C_RST}"
        echo "  ${C_DIM}---- 修改配置 ----${C_RST}"
        echo "  ${C_GRN}4${C_RST}. 基本设置       ${C_DIM}模式 / IP / 端口${C_RST}"
        echo "  ${C_GRN}5${C_RST}. 代理客户端   当前: ${C_GRN}$client${C_RST} ${C_DIM}(枚举选择)${C_RST}"
        echo "  ${C_GRN}6${C_RST}. 账号与解析池   ${C_DIM}邮箱 / API Key / 池条数${C_RST}"
        echo "  ${C_GRN}7${C_RST}. 测速设置       ${C_DIM}线程 / 延迟 / 丢包 / 地址${C_RST}"
        echo "  ${C_GRN}8${C_RST}. 高级参数       ${C_DIM}低频微调项${C_RST}"
        echo "  ${C_GRN}9${C_RST}. 验证与自愈     ${C_DIM}推送前验证 / 看门狗${C_RST}"
        echo "  ${C_GRN}10${C_RST}. IP列表与通知   ${C_DIM}TG / PushPlus${C_RST}"
        echo "  ${C_DIM}---- 查看 / 工具 ----${C_RST}"
        echo "  ${C_GRN}11${C_RST}. 运行状态"
        echo "  ${C_GRN}12${C_RST}. 显示当前配置"
        echo "  ${C_GRN}13${C_RST}. 测试通知"
        echo "  ${C_GRN}14${C_RST}. 回滚上次 DNS 快照"
        echo "  ${C_GRN}15${C_RST}. 更新 IP 列表"
        echo "  ${C_GRN}16${C_RST}. 定时任务       ${C_DIM}优选时刻 / 看门狗间隔${C_RST}"
        echo "  ${C_RED}0${C_RST}. 退出"
        echo
        read -rp "  ${C_GRN}请输入数字${C_RST} [0-16] ${C_DIM}(回车=退出)${C_RST}: " choice
        echo

        case "$choice" in
            1)
                echo "  将停止代理→测速→更新DNS→重启代理, 期间断网。"
                read -rp "  [1] 开始  [0] 取消: " c
                case "$c" in
                    1|y|Y) main ;;
                    *) echo "已取消" ;;
                esac
                ;;
            2)
                echo "  将停止代理→测速→恢复代理, 期间短暂断网, 不更新DNS。"
                read -rp "  [1] 开始  [0] 取消: " c
                case "$c" in
                    1|y|Y) test_only ;;
                    *) echo "已取消" ;;
                esac
                ;;
            3) config_init; config_validate; cf_verify_credentials; dns_update_main ;;
            4) config_init; config_edit_basic || true ;;
            5) config_init; config_change_client || true ;;
            6) config_init; config_edit_account || true ;;
            7) config_init; config_edit_speed || true ;;
            8) config_init; config_edit_adv || true ;;
            9) config_init; config_edit_verify || true ;;
            10) config_init; config_edit_notify || true ;;
            11) status ;;
            12) config_init; config_show ;;
            13) config_init; notify_all "测试通知" ;;
            14) config_init; config_validate; cf_verify_credentials; dns_rollback ;;
            15) config_init; config_validate; ip_list_update ;;
            16) config_init; config_edit_cron || true ;;
            0|"") echo "已退出"; break ;;
            *) echo "无效选项: $choice"; sleep 1; continue ;;
        esac

        read -rp "按回车键返回菜单..." _
    done
}

if [[ -z "${1:-}" && -t 0 ]]; then
    menu
    exit 0
fi

# CLI 子命令分发 (cron / 手动脚本调用)
case "${1:-run}" in
    run)
        main
        ;;

    config)
        config_interactive
        ;;

    show)
        config_show
        ;;

    test)
        test_only
        ;;

    dns)
        config_init
        config_validate
        cf_verify_credentials
        dns_update_main
        ;;

    status)
        status
        ;;

    notify)
        config_init
        notify_all "测试通知"
        ;;

    rollback)
        config_init
        config_validate
        cf_verify_credentials
        dns_rollback
        ;;

    ipupdate)
        config_init
        config_validate
        ip_list_update
        ;;

    *)
        echo "用法: $0 {run|config|show|test|dns|status|notify|rollback|ipupdate}"
        echo "  裸命令(交互终端)   - 数字菜单"
        echo "  run      - 执行完整优选流程 (默认, 适合 cron)"
        echo "  config   - 交互式配置"
        echo "  show     - 显示当前配置"
        echo "  test     - 仅测速 (含代理停启)"
        echo "  dns      - 仅更新 DNS"
        echo "  status   - 运行状态面板"
        echo "  notify   - 测试通知"
        echo "  rollback - 回滚上次 DNS 快照"
        echo "  ipupdate - 立即更新 IP 列表"
        exit 1
        ;;
esac