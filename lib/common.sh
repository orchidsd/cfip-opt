#!/bin/bash
# ============================================================================
# 公共工具库: 目录/文件变量、日志、JSON 读写、HTTP 封装、IP/域名校验、清理
# 所有 lib/*.sh 与 bin/*.sh 都先 source 本文件。
# 注意: 多处使用 [[ ]] 与数组等 bash 特性, 只能用 bash 运行(不能 sh)。
# ============================================================================
set -euo pipefail

# 目录/文件路径变量统一由脚本自身定义(可被环境变量覆盖), 默认按项目根推断
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${ROOT_DIR:=$(dirname "$SCRIPT_DIR")}"
: "${CONF_DIR:=$ROOT_DIR/conf}"
: "${IP_DIR:=$ROOT_DIR/ip}"
: "${BIN_DIR:=$ROOT_DIR/bin}"
: "${CFST_BIN:=$BIN_DIR/cfst}"
: "${CONFIG_FILE:=$CONF_DIR/config.json}"
: "${LOG_FILE:=$ROOT_DIR/informlog}"
: "${VERIFIED_FILE:=$ROOT_DIR/verified.txt}"
: "${REPORT_FILE:=$ROOT_DIR/dns_report}"
: "${SNAPSHOT_FILE:=$ROOT_DIR/snapshot.json}"
: "${LAST_SUMMARY:=$ROOT_DIR/last_summary}"
: "${WATCHDOG_FAIL:=$ROOT_DIR/watchdog_fail}"
: "${WATCHDOG_RUN_TS:=$ROOT_DIR/watchdog_last_run}"
: "${WATCHDOG_LAST:=$ROOT_DIR/watchdog_last_check}"

# 日志: 带时间戳/级别, 同时写入终端与 $LOG_FILE
log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

# 日志级别速记: INFO / WARN / ERROR / 致命(退出 1)
info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
die() { error "$@"; exit 1; }

# 确保命令存在, 缺失即退出
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
    done
}

require_file() {
    [[ -f "$1" ]] || die "文件不存在: $1"
}

# 从 config.json 读取值(空/null 时输出空, 不报错)
json_get() {
    local key="$1"
    jq -r "if ($key) == null then empty else $key end" "$CONFIG_FILE"
}

# 写入单个键值: 数字/布尔原样, 字符串加引号; 用临时文件原子替换防写坏
json_set() {
    local key="$1" value="$2"
    local tmp
    tmp=$(mktemp)
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" || "$value" == "false" ]]; then
        jq "$key = $value" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    else
        jq "$key = \"$value\"" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    fi
}

# 写入 JSON 原始表达式(如数组/对象), 不额外加引号
json_set_raw() {
    local key="$1" value="$2"
    local tmp
    tmp=$(mktemp)
    jq "$key = $value" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

# URL 百分号编码(供 query 参数拼接使用), 覆盖全部 ASCII 保留字符
url_encode() {
    local str="$1"
    printf '%s' "$str" | sed 's/[%]/%25/g; s/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/\*/%2A/g; s/+/%2B/g; s/,/%2C/g; s/-/%2D/g; s/\./%2E/g; s/\//%2F/g; s/:/%3A/g; s/;/%3B/g; s/</%3C/g; s/=/%3D/g; s/>/%3E/g; s/?/%3F/g; s/@/%40/g; s/\[/%5B/g; s/\\/%5C/g; s/\]/%5D/g; s/\^/%5E/g; s/_/%5F/g; s/`/%60/g; s/{/%7B/g; s/|/%7C/g; s/}/%7D/g; s/~/%7E/g'
}

# HTTP GET/POST/PUT/DELETE 封装 (curl, 带重试与超时, 可加自定义头)
http_get() {
    local url="$1" headers="${2:-}"
    local cmd="curl -sSfL --retry 3 --retry-delay 2 --max-time 15"
    [[ -n "$headers" ]] && cmd="$cmd -H \"$headers\""
    eval "$cmd \"$url\""
}

http_post() {
    local url="$1" data="$2" headers="${3:-}"
    local cmd="curl -sSfL --retry 3 --retry-delay 2 --max-time 15 -X POST -d \"$data\""
    [[ -n "$headers" ]] && cmd="$cmd -H \"$headers\""
    eval "$cmd \"$url\""
}

http_put() {
    local url="$1" data="$2" headers="${3:-}"
    local cmd="curl -sSfL --retry 3 --retry-delay 2 --max-time 15 -X PUT -d \"$data\""
    [[ -n "$headers" ]] && cmd="$cmd -H \"$headers\""
    eval "$cmd \"$url\""
}

http_delete() {
    local url="$1" headers="${2:-}"
    local cmd="curl -sSfL --retry 3 --retry-delay 2 --max-time 15 -X DELETE"
    [[ -n "$headers" ]] && cmd="$cmd -H \"$headers\""
    eval "$cmd \"$url\""
}

# IPv4 / IPv6 / 域名 格式校验 (正则级, 非权威, 仅防格式错误)
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && {
        local IFS=.
        set -- $1
        [[ $1 -le 255 && $2 -le 255 && $3 -le 255 && $4 -le 255 ]]
    }
}

is_ipv6() {
    [[ "$1" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]
}

is_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

# 清理 cfst 每次运行留下的临时 CSV/压缩包(脚本退出时自动执行)
cleanup_temp() {
    rm -f "$ROOT_DIR"/txt.zip "$ROOT_DIR"/a.csv "$ROOT_DIR"/b.csv "$ROOT_DIR"/cdnIP.csv "$ROOT_DIR"/pass.txt 2>/dev/null
}

# 任何退出路径都清理临时文件, 避免积攒
trap cleanup_temp EXIT INT TERM