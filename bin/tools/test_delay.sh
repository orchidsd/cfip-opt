#!/bin/bash
S=20000210s
H="Authorization: Bearer $S"
GRP=$(jq -r '.proxies|to_entries[]|select(.value.type=="URLTest")|.key' /tmp/prox.json | head -1)
U=$(jq -rn --arg x "$GRP" '$x|@uri')
echo "GRP=$GRP  U=$U"
echo "== delay 测速 =="
curl -s --max-time 30 -H "$H" \
  "http://127.0.0.1:9090/proxies/$U/delay?url=http://www.gstatic.com/generate_204&timeout=8000"
echo
echo "== 换成 https 测速 =="
curl -s --max-time 30 -H "$H" \
  "http://127.0.0.1:9090/proxies/$U/delay?url=https://cp.cloudflare.com/generate_204&timeout=8000"
echo
echo "== 该组所有节点 =="
jq -r --arg g "$GRP" '.proxies[$g].all[]' /tmp/prox.json | head -20