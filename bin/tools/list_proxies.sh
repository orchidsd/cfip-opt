#!/bin/bash
S=20000210s
H="Authorization: Bearer $S"
curl -s --max-time 8 -H "$H" http://127.0.0.1:9090/proxies > /tmp/prox.json
echo "bytes: $(wc -c < /tmp/prox.json)"
jq -r '.proxies|to_entries|map(.value.type)|unique|join(" ")' /tmp/prox.json
echo "--- URLTest 组 ---"
jq -r '.proxies|to_entries[]|select(.value.type=="URLTest")|.key' /tmp/prox.json | head -5
echo "--- Selector / 含 test 的组 ---"
jq -r '.proxies|to_entries[]|select(.value.type=="Selector" and ((.value.all|length)>0))|.key' /tmp/prox.json | head -8