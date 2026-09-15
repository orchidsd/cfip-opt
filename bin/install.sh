#!/bin/bash
# ============================================================================
# Cloudflare 优选 IP - 一键安装脚本
#
# 两种用法（都能在任何 OpenWrt / Alpine / Debian / CentOS 上运行）:
#   1) 就地安装(推荐): 把整个项目 scp 上路由器后
#        cd /root/cfip-opt && bash bin/install.sh
#   2) 远程一键安装(不依赖 git):
#        bash -c 'curl -fsSL https://github.com/orchidsd/cfip-opt/archive/refs/heads/main.tar.gz | tar xz -C /tmp && mv /tmp/cfip-opt-main /tmp/cfip-opt && bash /tmp/cfip-opt/bin/install.sh'
#        国内不通时把 URL 换成 https://ghfast.top/https://github.com/... 即可
#
# 做的事: 安装系统依赖(bash/jq/curl/...) -> 按架构下载 cfst 测速二进制
#        -> 准备 IP 文本 -> 生成配置文件 -> 注册定时任务/cfip 命令
# 幂等: 重复执行不会重复安装/重复加 cron。
# ============================================================================
set -euo pipefail

# 允许环境变量覆盖安装目录（远程引导默认装到 /root/cfip-opt）
INSTALL_DIR="${INSTALL_DIR:-/root/cfip-opt}"

# 远程引导用的仓库地址（git 仓库或 tar.gz 包地址）
REPO_URL="${REPO_URL:-https://github.com/orchidsd/cfip-opt.git}"

# --------------------------------------------------------------------------
# 第 0 步: 项目文件定位(就地/已装/远程引导) —— 必须在 source common 之前,
# 否则路径变量(IINSTALL_DIR/BIN_DIR/...)会指向错误位置。
# --------------------------------------------------------------------------
SELF_DIR=""
case "$0" in
    *install.sh) SELF_DIR=$(cd "$(dirname "$0")" && pwd) ;;
esac

if [[ -n "$SELF_DIR" && -f "$SELF_DIR/../lib/common.sh" ]]; then
    # 就地模式: 本脚本位于项目内 bin/install.sh, 项目根 = bin 的上一级
    INSTALL_DIR="$(cd "$SELF_DIR/.." && pwd)"
elif [[ -f "$INSTALL_DIR/lib/common.sh" ]]; then
    # 目标目录已存在完整项目(上次已装) -> 直接进入常规安装流程
    :
else
    # 远程引导: 从 REPO_URL 拉取源码铺到 $INSTALL_DIR (本段用 echo, 尚无 common)
    echo "[install] 未找到项目文件, 从仓库引导到 $INSTALL_DIR ..."
    if [[ -z "${REPO_URL:-}" ]]; then
        echo "[install] 未提供 REPO_URL, 无法远程引导"; exit 1
    fi
    tmp=$(mktemp -d)
    if [[ "$REPO_URL" == *.git ]]; then
        git clone --depth 1 "$REPO_URL" "$tmp/repo"
    else
        curl -fsSL --connect-timeout 10 --max-time 300 -o "$tmp/src.tgz" "$REPO_URL"
        mkdir -p "$tmp/repo"
        tar -xzf "$tmp/src.tgz" -C "$tmp/repo" --strip-components=1
    fi
    [[ -f "$tmp/repo/lib/common.sh" ]] || { rm -rf "$tmp"; echo "[install] 仓库内容不是本项目, 请检查 REPO_URL"; exit 1; }
    mkdir -p "$INSTALL_DIR"
    cp -a "$tmp/repo/." "$INSTALL_DIR/"
    rm -rf "$tmp"
    echo "[install] 项目源码已就位: $INSTALL_DIR"
fi

# 加载日志/工具函数(此时 INSTALL_DIR 已定, 路径才对)
source "$INSTALL_DIR/lib/common.sh"
source "$INSTALL_DIR/lib/ip_test.sh"

# 目录常量(与 common.sh 一一对应)
BIN_DIR="$INSTALL_DIR/bin"
LIB_DIR="$INSTALL_DIR/lib"
CONF_DIR="$INSTALL_DIR/conf"
IP_DIR="$INSTALL_DIR/ip"

detect_arch() {
    # 将系统架构(uname -m)映射为 cfst release 包的后缀名
    case "$(uname -m)" in
        x86_64|x64|amd64) echo "amd64" ;;
        i386|i686) echo "386" ;;
        aarch64|arm64|armv8|armv8l) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        armv6l|armv6) echo "armv6" ;;
        armv5l|armv5) echo "armv5" ;;
        mips64le) echo "mips64le" ;;
        mips64) echo "mips64" ;;
        mips|mipsle) echo "mipsle" ;;
        *) echo "unknown" ;;
    esac
}

install_deps() {
    # 侦测缺失的命令并分配对应的软件包名, 按发行版包管理器补齐
    local pkgs=()
    local cmds=(bash jq wget curl sed unzip tr timeout base64)
    local pkg_names=(bash jq wget curl sed unzip coreutils coreutils-timeout coreutils-base64)

    for i in "${!cmds[@]}"; do
        command -v "${cmds[i]}" >/dev/null 2>&1 || pkgs+=("${pkg_names[i]}")
    done

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        info "所有依赖已满足"
        return 0
    fi

    info "安装依赖: ${pkgs[*]}"

    if grep -qi "openwrt" /etc/os-release /etc/issue /proc/version 2>/dev/null; then
        opkg update
        opkg install "${pkgs[@]}"
    elif grep -qi "alpine" /etc/os-release /etc/issue /proc/version 2>/dev/null; then
        apk update
        apk add "${pkgs[@]}"
    elif grep -qi "ubuntu\|debian" /etc/os-release /etc/issue /proc/version 2>/dev/null; then
        apt-get update -y
        apt-get install -y "${pkgs[@]}"
    elif grep -qi "centos\|red hat\|redhat" /etc/os-release /etc/issue /proc/version 2>/dev/null; then
        yum install -y "${pkgs[@]}"
    else
        warn "未识别的系统，请手动安装: ${pkgs[*]}"
        return 1
    fi
}

download_cfst() {
    # 已有可用二进制则跳过下载(幂等, 避免重复拉取)
    if [[ -x "$BIN_DIR/cfst" ]]; then
        info "cfst 已存在: $BIN_DIR/cfst"
        return 0
    fi
    # 下载 CloudflareST 测速二进制, 依次尝试官方 + GH 加速镜像
    local arch
    arch=$(detect_arch)
    [[ "$arch" != "unknown" ]] || die "不支持的架构: $(uname -m)"

    local mirrors=(
        "https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download"
        "https://ghfast.top/https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download"
        "https://ghproxy.net/https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download"
    )

    info "下载 cfst ($arch)..."

    local tmp fetched binary ip_pkg ip6_pkg url
    tmp=$(mktemp -d)
    fetched=""

    for base in "${mirrors[@]}"; do
        url="$base/cfst_linux_${arch}.tar.gz"
        info "尝试: $url"
        if curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp/cfst.tmp" "$url" 2>/dev/null; then
            fetched=1
            break
        fi
        rm -f "$tmp/cfst.tmp"
    done

    [[ -n "$fetched" ]] || { rm -rf "$tmp"; die "cfst 下载失败，请检查网络，或手动下载放入 $BIN_DIR/cfst 后重试"; }

    tar -xzf "$tmp/cfst.tmp" -C "$tmp" 2>/dev/null
    binary=$(find "$tmp" -type f \( -name cfst -o -name CloudflareST \) 2>/dev/null | head -n1)
    [[ -n "$binary" ]] || { rm -rf "$tmp"; die "解压后未找到 cfst 二进制"; }

    mv "$binary" "$BIN_DIR/cfst"
    chmod +x "$BIN_DIR/cfst"
    info "cfst 安装成功"

    # v2.x 压缩包自带 IP 文本, 直接复用, 减少被墙源依赖
    ip_pkg=$(find "$tmp" -type f -name "ip.txt" 2>/dev/null | head -n1)
    ip6_pkg=$(find "$tmp" -type f -name "ipv6.txt" 2>/dev/null | head -n1)
    [[ -n "$ip_pkg" ]] && [[ -s "$ip_pkg" ]] && cp "$ip_pkg" "$IP_DIR/ip.txt"
    [[ -n "$ip6_pkg" ]] && [[ -s "$ip6_pkg" ]] && cp "$ip6_pkg" "$IP_DIR/ipv6.txt"

    rm -rf "$tmp"
}

download_ip_lists() {
    # 优先用 cfst 压缩包带出的列表(download_cfst 里已复制), 缺失才在线拉取
    [[ -s "$IP_DIR/ip.txt" ]] && { info "IPv4 列表已就绪"; } || {
        warn "缺乏 IPv4 列表，从镜像下载..."
local urls=(
        "https://www.cloudflare.com/ips-v4"
        "https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ip.txt"
        "https://raw.gitmirror.com/XIU2/CloudflareSpeedTest/master/ip.txt"
        "https://ghproxy.net/https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ip.txt"
    )
    local url
    for url in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$IP_DIR/ip.txt.tmp" "$url" 2>/dev/null \
            && [[ -s "$IP_DIR/ip.txt.tmp" ]]; then
            if [[ "$url" == *"cloudflare.com/ips-v4" ]]; then
                _expand_official_v4 < "$IP_DIR/ip.txt.tmp" > "$IP_DIR/ip.txt"
                rm -f "$IP_DIR/ip.txt.tmp"
            else
                mv "$IP_DIR/ip.txt.tmp" "$IP_DIR/ip.txt"
            fi
            info "IPv4 列表下载完成 ($url)"
            break
        fi
        rm -f "$IP_DIR/ip.txt.tmp"
    done
        [[ -s "$IP_DIR/ip.txt" ]] || warn "IPv4 列表下载失败，可稍后手动放入 $IP_DIR/ip.txt"
    }

    [[ -s "$IP_DIR/ipv6.txt" ]] && { info "IPv6 列表已就绪"; } || {
        warn "缺乏 IPv6 列表，从镜像下载..."
        local urls=(
            "https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ipv6.txt"
            "https://raw.gitmirror.com/XIU2/CloudflareSpeedTest/master/ipv6.txt"
            "https://ghproxy.net/https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ipv6.txt"
        )
        local url
        for url in "${urls[@]}"; do
            if curl -fsSL --connect-timeout 10 --max-time 60 -o "$IP_DIR/ipv6.txt" "$url" 2>/dev/null \
                && [[ -s "$IP_DIR/ipv6.txt" ]]; then
                info "IPv6 列表下载完成"
                break
            fi
        done
        [[ -s "$IP_DIR/ipv6.txt" ]] || warn "IPv6 列表下载失败，仅 IPv4 可用"
    }
}

setup_config() {
    # 首次安装生成默认配置; 已存在则跳过(保留用户修改)
    if [[ -f "$CONF_DIR/config.json" ]]; then
        info "配置文件已存在: $CONF_DIR/config.json"
    else
        cp "$CONF_DIR/config.json.example" "$CONF_DIR/config.json"
        info "已生成默认配置, 下一步请输入 Cloudflare 账号等信息"
    fi
}

setup_cron() {
    # 每天 5/13/21 点优选一次; watchdog 每 5 分钟自检; 均已去重
    local run_expr="0 5,13,21 * * * $BIN_DIR/cfip-opt.sh run"
    if ! crontab -l 2>/dev/null | grep -q "cfip-opt.sh run"; then
        (crontab -l 2>/dev/null; echo "$run_expr") | crontab -
        info "已添加定时任务: 每天 5/13/21 点优选"
    else
        info "优选定时任务已存在"
    fi

    local wd_expr="*/5 * * * * $BIN_DIR/watchdog.sh >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
        (crontab -l 2>/dev/null; echo "$wd_expr") | crontab -
        info "已添加看门狗定时任务: 每 5 分钟自检"
    else
        info "看门狗定时任务已存在"
    fi
}

setup_cfip_cmd() {
    # 提供全局 cfip 命令, 方便在任何目录进入交互菜单
    ln -sf "$BIN_DIR/cfip-opt.sh" /usr/bin/cfip
    info "已创建命令: cfip（重登 shell 后生效）"
}

main() {
    info "=== Cloudflare 优选 IP 安装程序 (安装目录: $INSTALL_DIR) ==="

    mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONF_DIR" "$IP_DIR"

    install_deps
    download_cfst
    download_ip_lists
    setup_config
    setup_cron
    setup_cfip_cmd

    info "=== 安装完成 ==="
    echo
    echo "下一步："
    echo "1. 录入 Cloudflare 凭据与池条数: cfip  -> [5] 账号与解析池"
    echo "2. 调整测速参数:                 cfip  -> [0] 启动交互配置(或直接改 conf/config.json)"
    echo "3. 首次试跑:                     $BIN_DIR/cfip-opt.sh run"
    echo "4. 查看运行状态:                 cfip  -> [11] 运行状态"
}

main "$@"