#!/bin/bash
cd /root/cfip-opt/conf || exit 1
jq '.cloudflare.min_records = 10 | .cloudflare.max_records = 24' config.json > tmp.json && mv tmp.json config.json
jq '.cloudflare | {min_records, max_records, keep_days, strategy, subdomain, domain}' config.json