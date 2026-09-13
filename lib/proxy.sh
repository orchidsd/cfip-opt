#!/bin/bash
# ============================================================================
# 代理服务管理模块
# 统一把配置的 proxy_client 名字映射为 OpenWrt init.d 服务名,
# 提供 stop(测速前) 与 restart(测速后) 两个动作。
# 测速必须停代理: 否则流量走隧道, 测得的延迟/速度反映的是代理链路而非 CF 边缘。
# ============================================================================
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
        /etc/init.d/"$service" stop
    else
        warn "服务脚本不存在: /etc/init.d/$service"
    fi
}

proxy_restart() {
    local client service wait_sec
    client=$(json_get '.proxy_client')
    [[ "$client" == "none" ]] && { info "未配置代理客户端，跳过重启"; return 0; }

    service=$(proxy_client_to_service "$client")
    [[ -n "$service" ]] || { warn "未知代理客户端: $client"; return 1; }

    wait_sec=$(json_get '.restart_wait_sec')

    if [[ -f "/etc/init.d/$service" ]]; then
        info "重启代理服务: $service"
        /etc/init.d/"$service" restart
        info "等待 $wait_sec 秒让服务稳定..."
        sleep "$wait_sec"
    else
        warn "服务脚本不存在: /etc/init.d/$service"
    fi
}