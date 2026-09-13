#!/bin/bash
# ============================================================================
# Cloudflare 优选 IP - 卸载脚本
# 移除: 优选/看门狗定时任务、全局 cfip 命令、整个安装目录
# 用法: bash $INSTALL_DIR/bin/uninstall.sh
# ============================================================================
set -euo pipefail

# 安装目录自动取本脚本上级(与本目录布局解耦, 允许移到别处)
readonly INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly BIN_DIR="$INSTALL_DIR/bin"

main() {
    echo "=== 卸载 Cloudflare 优选 IP ==="

    # 询问确认, 避免误删
    read -rp "确认删除 $INSTALL_DIR 及其所有数据和定时任务? [y/N]: " c
    [[ "$c" == "y" || "$c" == "Y" ]] || { echo "已取消"; exit 0; }

    # 移除定时任务(优选 + 看门狗两条 cron 行)
    if crontab -l 2>/dev/null | grep -qE "cfip-opt.sh|watchdog"; then
        crontab -l 2>/dev/null | grep -vE "cfip-opt.sh|watchdog" | crontab -
        echo "已移除定时任务"
    fi

    # 移除全局命令软链
    if [[ -L /usr/bin/cfip ]]; then
        rm -f /usr/bin/cfip
        echo "已移除命令: cfip"
    fi

    # 移除安装目录
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        echo "已删除安装目录: $INSTALL_DIR"
    fi

    echo "=== 卸载完成 ==="
}

main "$@"