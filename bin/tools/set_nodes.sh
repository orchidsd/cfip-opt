#!/bin/bash
cd /root/cfip-opt/conf
jq '.cloudflare.node_domains = "page1.weiguang1.eu.org,page1.weiguang.eu.org,page1.weiguang2.eu.org,page1.weiguang3.eu.org,page1.weiguang4.eu.org,pages1.nicdns.dpdns.org,pages1.weiguang.dpdns.org,pages1.orchid.dpdns.org"' config.json > tmp.json && mv tmp.json config.json
bash /root/cfip-opt/bin/cfip-opt.sh show > /dev/null 2>&1 && echo VALID_OK
jq -c '.cloudflare | {domain, subdomain, node_domains}' config.json