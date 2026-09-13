#!/bin/bash
/etc/init.d/openclash stop >/dev/null 2>&1 || true
sleep 3
pkill -9 -f "/etc/openclash/clash" 2>/dev/null || true
sleep 1
/etc/init.d/openclash start >/dev/null 2>&1 || true
sleep 15
netstat -ltnp 2>/dev/null | grep ':9090 ' || true