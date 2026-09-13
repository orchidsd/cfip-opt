#!/bin/bash
for p in $(ps w | grep -E '[c]fst|[c]fip-opt.sh' | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
done
sleep 1
rm -f /tmp/cfip_run2.log
nohup bash /root/cfip-opt/bin/cfip-opt.sh run > /tmp/cfip_run2.log 2>&1 &
echo "STARTED pid=$!"
ps w | grep -E '[c]fst|[c]fip-opt.sh run' | grep -v grep