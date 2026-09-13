#!/bin/bash
for p in $(ps w | grep -E '[c]fst|cfip-opt.sh' | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1
cd /root/cfip-opt/conf
jq '.speed_test.url = "http://speed.cloudflare.com/__down?bytes=5242880"' config.json > tmp.json && mv tmp.json config.json
echo "--- url now ---"
jq -r '.speed_test.url' config.json