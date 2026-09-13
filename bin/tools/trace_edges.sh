#!/bin/bash
S=20000210s
H="Authorization: Bearer $S"
echo "== 当前 config log-level =="
curl -s --max-time 8 -H "$H" http://127.0.0.1:9090/configs | jq -r '."log-level"'
echo "== PATCH 设 debug =="
curl -s --max-time 8 -X PATCH -H "$H" -H "Content-Type: application/json" \
  -d '{"log-level":"debug"}' http://127.0.0.1:9090/configs
echo
curl -s --max-time 8 -H "$H" http://127.0.0.1:9090/configs | jq -r '."log-level"'
START=$(wc -l < /tmp/openclash.log)
for n in "6自用yoki.weiguang.eu.org" "6自用pages1.weiguang1.eu.org-clone" "6自用pages1.orchid.dpdns.org-clone"; do
  U=$(jq -rn --arg x "$n" '$x|@uri')
  echo -n "### $n => "
  curl -s --max-time 22 -H "$H" \
    "http://127.0.0.1:9090/proxies/$U/delay?url=https://www.gstatic.com/generate_204&timeout=8000"
  echo
  sleep 2
done
END=$(wc -l < /tmp/openclash.log)
echo "== 新增日志行数: $((END-START)) =="
sed -n "$((START+1)),${END}p" /tmp/openclash.log > /tmp/win.log
grep -E 'cdn\.weiguang1|dial|Lookup|resolve|websocket|handshake|level=debug+.*(err|fail|error|conn|dial)' /tmp/win.log | tail -70
echo "== 全部 debug 行数 =="
grep -c 'level=debug' /tmp/win.log || true