#!/bin/bash
set -e
CFG=/root/cfip-opt/conf/config.json
[[ -f "$CFG" ]] || { echo "no $CFG"; exit 1; }
jq '.verify.ws_test = true | .verify.ws_path = "/"' "$CFG" > tmp.json && mv tmp.json "$CFG"
echo "== verify 配置 =="
jq -c '.verify' "$CFG"
echo "== 校验 =="
cd /root/cfip-opt
bash lib/config.sh validate 2>&1 | tail -3 || true