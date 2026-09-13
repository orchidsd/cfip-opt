#!/bin/bash
cd /root/cfip-opt/conf
jq '.speed_test.enabled = true | .speed_test.url = "http://speed.cloudflare.com/__down?bytes=99999999"' config.json > tmp.json && mv tmp.json config.json
jq '.speed_test | {enabled, url, avg_latency_max, download_speed_min}' config.json