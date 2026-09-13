#!/bin/bash
for p in $(ps w | grep -E '[c]fst|[c]fip-opt.sh test' | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1
echo "--- remaining cfst/cfip ---"
ps w | grep -E '[c]fst|[c]fip' | grep -v grep
echo "--- openclash ---"
/etc/init.d/openclash status
nohup bash /root/cfip-opt/bin/cfip-opt.sh run > /tmp/cfip_run.log 2>&1 &
echo "--- full run started, log=/tmp/cfip_run.log ---"