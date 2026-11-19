#!/usr/bin/env bash
# Data loss: pause replication, keep writing in the primary, then lose the primary.
# t=60 pause replication (5 min) | t=120 primary app down | t=240 count writes missing in the standby
# t=360 replication resumes | t=420 primary back | t=480 count again | end t=600
set -euo pipefail
cd "$(dirname "$0")/.."; source infra/env.sh
RUN=${1:-exp3-rpo}; EV=results/raw/$RUN.events; : > $EV
caffeinate -dimsu k6 run -q -e RUN=$RUN -e NO_REUSE=1 -e DURATION=600s test/failover.js \
  --console-output results/raw/$RUN.jsonl > results/raw/$RUN.k6.txt 2>&1 &
K6=$!
at() { sleep $(( $1 - $(( $(date +%s) - START )) )); }
START=$(date +%s); python3 -c 'import time;print("start",int(time.time()*1000))' >> $EV
at 60;  test/break.sh pause-replication | tee -a $EV
at 120; test/break.sh app-down | tee -a $EV
at 240; echo "snapshot at $(python3 -c 'import time;print(int(time.time()*1000))')" | tee -a $EV
        python3 test/analyze.py results/raw/$RUN.jsonl --check-region $SECONDARY | tail -2 | tee -a $EV
at 420; test/break.sh app-up 2 | tee -a $EV
at 480; echo "snapshot at $(python3 -c 'import time;print(int(time.time()*1000))')" | tee -a $EV
        python3 test/analyze.py results/raw/$RUN.jsonl --check-region $SECONDARY | tail -2 | tee -a $EV
wait $K6 || true; echo "done: results/raw/$RUN.jsonl"
