#!/bin/bash
S=20000210s
H="Authorization: Bearer $S"
curl -s --max-time 8 -H "$H" http://127.0.0.1:9090/proxies > /tmp/prox.json
GRP=$(jq -r '.proxies|keys[]|select(contains("自用优选"))' /tmp/prox.json | head -1)
echo "GRP=$GRP"
echo "== 组信息 =="
jq -r --arg g "$GRP" '.proxies[$g]' /tmp/prox.json
echo "== 组成员(节点) =="
mapfile -t NODES < <(jq -r --arg g "$GRP" '.proxies[$g].all[]' /tmp/prox.json)
printf '%s\n' "${NODES[@]}"
echo "== 组延迟测试 =="
U=$(jq -rn --arg x "$GRP" '$x|@uri')
curl -s --max-time 30 -H "$H" \
  "http://127.0.0.1:9090/proxies/$U/delay?url=http://www.gstatic.com/generate_204&timeout=8000"
echo
echo "== 逐个节点延迟 =="
for n in "${NODES[@]}"; do
  un=$(jq -rn --arg x "$n" '$x|@uri')
  d=$(curl -s --max-time 25 -H "$H" \
      "http://127.0.0.1:9090/proxies/$un/delay?url=http://www.gstatic.com/generate_204&timeout=8000")
  printf '%-45s %s\n' "$n" "$d"
done