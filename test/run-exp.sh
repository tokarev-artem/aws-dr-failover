#!/usr/bin/env bash
# One experiment: load for TOTAL seconds, fault at FAULT_AT, undo at UNDO_AT.
# usage: run-exp.sh <run-name> <fault> <undo> [FAULT_AT=120] [UNDO_AT=420] [TOTAL=600]
set -euo pipefail
cd "$(dirname "$0")/.."
RUN=$1 FAULT=$2 UNDO=$3 FAULT_AT=${4:-120} UNDO_AT=${5:-420} TOTAL=${6:-600}
mkdir -p results/raw; EV=results/raw/$RUN.events; : > $EV
caffeinate -dimsu k6 run -q -e RUN=$RUN -e NO_REUSE=${NO_REUSE:-0} -e DURATION=${TOTAL}s test/failover.js \
  --console-output results/raw/$RUN.jsonl > results/raw/$RUN.k6.txt 2>&1 &
K6=$!
python3 -c 'import time;print("start",int(time.time()*1000))' >> $EV
sleep $FAULT_AT; test/break.sh $FAULT | tee -a $EV
sleep $((UNDO_AT - FAULT_AT)); test/break.sh $UNDO | tee -a $EV
wait $K6 || true
echo "done: results/raw/$RUN.jsonl"
