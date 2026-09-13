#!/bin/bash
# WS 探测行为测试: 对已知好边 108.162.198.41 与慢边 104.24.5.11, 用节点域名 SNI 试多种 WS 升级形态
NODE=page1.weiguang2.eu.org
KEY=dGhlIHNhbXBsZSBub25jZQ==
for IP in 108.162.198.41 104.24.5.11; do
  for P in "/" "/?proxyip=ProxyIP.HK.CMLiussss.net" "/?ed=2048"; do
    out=$(curl -sS -o /dev/null --connect-timeout 5 --max-time 10 \
        --resolve "$NODE:443:$IP" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $KEY" \
        -w 'code=%{http_code} st=%{time_starttransfer} err=%{errormsg}' \
        "https://${NODE}${P}" 2>&1) || out="curl-fail: $out"
    printf '%-16s %-38s %s\n' "$IP" "$P" "$out"
  done
  echo
done