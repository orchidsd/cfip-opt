#!/bin/bash
CFG=/root/cfip-opt/conf/config.json
jq '.cloudflare.min_records = 5 | .cloudflare.max_records = 5' "$CFG" > /tmp/c && mv /tmp/c "$CFG"
jq -c '.cloudflare | {domain, subdomain, min_records, max_records}' "$CFG"