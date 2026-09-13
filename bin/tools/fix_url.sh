#!/bin/bash
cd /root/cfip-opt/conf
jq '.speed_test.url = "https://speed.cloudflare.com/__down?bytes=99999999"' config.json > tmp.json && mv tmp.json config.json
jq -r '.speed_test.url' config.json