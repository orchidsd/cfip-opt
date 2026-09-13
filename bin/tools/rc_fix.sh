#!/bin/bash
# 干净重启 OpenClash 并验证面板 API + 节点延迟测试
set -euo pipefail
LOG=/tmp/rc_fix.log
: > "$LOG"

echo "== 1. 停止 OpenClash (连残留一起清) ==" | tee -a "$LOG"
/etc/init.d/openclash stop >> "$LOG" 2>&1 || true
sleep 3
pkill -f "/etc/openclash/clash" 2>/dev/null && sleep 2 || true
pgrep -f "/etc/openclash/clash" >/dev/null && echo "仍有 clash, 强杀" >> "$LOG" || echo "已清空" >> "$LOG"
pkill -9 -f "/etc/openclash/clash" 2>/dev/null || true
sleep 1

echo "== 2. 启动 OpenClash ==" | tee -a "$LOG"
/etc/init.d/openclash start >> "$LOG" 2>&1 || true
sleep 15

echo "== 3. 9090 归属与版本 ==" | tee -a "$LOG"
netstat -ltnp 2>/dev/null | grep -E ':9090 ' | tee -a "$LOG"
S=20000210s
curl -s --max-time 5 -H "Authorization: Bearer $S" http://127.0.0.1:9090/version | tee -a "$LOG"
echo
curl -s --max-time 5 -H "Authorization: Bearer $S" http://127.0.0.1:9090/configs | head -c 300 | tee -a "$LOG"
echo

echo "== 4. 节点延迟测试 (动态挑一个 url-test 分组) ==" | tee -a "$LOG"
H="Authorization: Bearer $S"
GRP=$(curl -s --max-time 8 -H "$H" http://127.0.0.1:9090/proxies \
      | jq -r '.proxies|to_entries[]|select(.value.type=="URLTest")|.key' | head -1)
echo "测试分组: $GRP" | tee -a "$LOG"
U=$(jq -rn --arg x "$GRP" '$x|@uri')
curl -s --max-time 12 -H "$H" \
  "http://127.0.0.1:9090/proxies/$U/delay?url=http://www.gstatic.com/generate_204&timeout=5000" \
  | tee -a "$LOG"
echo
echo "== 完成 ==" | tee -a "$LOG"