#!/bin/bash
cd /root/cfip-opt/conf
jq '.speed_test.colo = "TPE,HKG,NRT,HND,KIX,SIN,LAX,SJC,SEA,OKA,ICN,FRA"' config.json > tmp.json && mv tmp.json config.json
bash /root/cfip-opt/bin/cfip-opt.sh show | grep -E '测速|col|机场|模式'