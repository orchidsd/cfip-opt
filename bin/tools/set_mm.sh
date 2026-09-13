#!/bin/bash
CFG=/root/cfip-opt/conf/config.json
jq '.verify.max_ms = 200' "$CFG" > /tmp/c && mv /tmp/c "$CFG"
jq -c '.verify' "$CFG"