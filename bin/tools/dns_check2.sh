#!/bin/bash
S=20000210s
H="Authorization: Bearer $S"
echo "--- raw POST dns/query ---"
curl -s --max-time 8 -X POST -H "$H" -H "Content-Type: application/json" \
  -d '{"hostname":"cdn.weiguang1.eu.org"}' http://127.0.0.1:9090/dns/query
echo
echo "--- raw GET ---"
curl -s --max-time 8 -H "$H" "http://127.0.0.1:9090/dns/query?host=cdn.weiguang1.eu.org&type=v4"
echo
echo "--- core 侧 nameserver 是否假IP: 查 mihomo 最近日志中 cdn 的解析 ---"
grep -o 'cdn.weiguang1.eu.org[^"]*' /tmp/openclash.log | tail -5 || true