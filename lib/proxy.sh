#!/bin/bash
# ============================================================================
# 代理服务管理模块
# 统一把配置的 proxy_client 名字映射为 OpenWrt init.d 服务名,
# 提供 stop(测速前) 与 restart(测速后) 两个动作。
# 测速必须停代理: 否则流量走隧道, 测得的延迟/速度反映的是代理链路而非 CF 边缘。
# ============================================================================
# shellcheck source=lib/common.sh
: "${LIB_DIR:="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"}"
source "$LIB_DIR/common.sh"

# 调用 init.d 脚本并限时等待: openclash 的 status/start 子命令会挂起(见 AGENTS)
# timeout 可用则限时 60s, 否则直接调用
initd_call() {
    local svc="$1" act="$2"
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "/etc/init.d/$svc" "$act"
    else
        "/etc/init.d/$svc" "$act"
    fi
}

proxy_start() {
    local client service
    client=$(json_get '.proxy_client')
    [[ "$client" == "none" ]] && { info "未配置代理客户端，跳过启动"; return 0; }

    service=$(proxy_client_to_service "$client")
    [[ -n "$service" ]] || { warn "未知代理客户端: $client"; return 1; }

    if [[ -f "/etc/init.d/$service" ]]; then
        info "启动代理服务: $service"
        initd_call "$service" start
    else
        warn "服务脚本不存在: /etc/init.d/$service"
    fi
}

# 客户端别名 -> OpenWrt 服务名(init.d 下的脚本名), 不支持则返回空串
proxy_client_to_service() {
    local client="$1"
    case "$client" in
        passwall) echo "passwall" ;;
        passwall2) echo "passwall2" ;;
        shadowsocksr) echo "shadowsocksr" ;;
        clash) echo "clash" ;;
        openclash) echo "openclash" ;;
        bypass) echo "bypass" ;;
        v2raya) echo "v2raya" ;;
        hello-world) echo "helloworld" ;;
        homeproxy) echo "homeproxy" ;;
        mihomo) echo "mihomo" ;;
        shellcrash) echo "shellcrash" ;;
        none) echo "" ;;
        *) echo "" ;;
    esac
}

proxy_stop() {
    local client service
    client=$(json_get '.proxy_client')
    [[ "$client" == "none" ]] && { info "未配置代理客户端，跳过停止"; return 0; }

    service=$(proxy_client_to_service "$client")
    [[ -n "$service" ]] || { warn "未知代理客户端: $client"; return 1; }

    if [[ -f "/etc/init.d/$service" ]]; then
        info "停止代理服务: $service"
        initd_call "$service" stop
    else
        warn "服务脚本不存在: /etc/init.d/$service"
    fi
}

# 保证代理一定恢复(供 EXIT trap 兜底, 防止测速中途失败后代理一直停在停止态断网)
PROXY_RESTORED=0
proxy_ensure_restored() {
    [[ "$PROXY_RESTORED" == "1" ]] && return 0
    PROXY_RESTORED=1
    proxy_restart >/dev/null 2>&1 || true
}

proxy_restart() {
    local client service wait_sec
    client=$(json_get '.proxy_client')
    [[ "$client" == "none" ]] && { info "未配置代理客户端，跳过重启"; return 0; }

    service=$(proxy_client_to_service "$client")
    [[ -n "$service" ]] || { warn "未知代理客户端: $client"; return 1; }

    wait_sec=$(json_get '.restart_wait_sec')
    [[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=30

    if [[ -f "/etc/init.d/$service" ]]; then
        info "重启代理服务: $service"
        initd_call "$service" restart
        info "等待 $wait_sec 秒让服务稳定..."
        sleep "$wait_sec"
    else
        warn "服务脚本不存在: /etc/init.d/$service"
    fi
}