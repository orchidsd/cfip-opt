#!/bin/bash
S=20000210s
H="Authorization: Bearer $S"
for d in cdn.weiguang1.eu.org yoki.weiguang.eu.org page1.weiguang1.eu.org; do
  echo "== $d =="
  curl -s --max-time 8 -X POST -H "$H" -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$d\"}" http://127.0.0.1:9090/dns/query | jq -r '.result // . | {type: (.Answer // []|map(.type)|join(",")), data:(.Answer // []|map(.data)|join(" "))}'
done