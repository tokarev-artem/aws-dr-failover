#!/usr/bin/env bash
# Recompute every run's numbers into results/summary.txt
cd "$(dirname "$0")/.."; source infra/env.sh
ev() { awk -v k="$2" '$1==k && $2=="at"{print $3; exit}' results/raw/$1.events; }
run() { # run fault-event undo-event
  echo "######## $1"
  python3 test/analyze.py results/raw/$1.jsonl --fault-at $(ev $1 $2) ${3:+--undo-at $(ev $1 $3)} --bucket 10 --check-region $SECONDARY | grep -v '^ *-\?[0-9]\+ ' | grep -v '^$'
}
{
run exp1-app-down app-down app-up
run exp1b-app-down-newconn app-down app-up
run exp2a-db-down-shallow db-down
run exp2a-fis-shallow fis
run exp2b-fis-deep fis
run exp3-rpo-b app-down app-up
grep -A2 snapshot results/raw/exp3-rpo-b.events
run exp4-pilot-light pilot-failover app-up
} > results/summary.txt 2>&1
cat results/summary.txt
