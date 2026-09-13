#!/bin/bash
cd /root/cfip-opt/conf
jq '.speed_test.test_times = 4 | .speed_test.download_timeout = 15 | .speed_test.display_results = 10 | .speed_test.packet_loss_max = 1.00' config.json > tmp.json && mv tmp.json config.json
bash /root/cfip-opt/bin/cfip-opt.sh show > /dev/null 2>&1 && echo VALID_OK
jq '.speed_test' config.json