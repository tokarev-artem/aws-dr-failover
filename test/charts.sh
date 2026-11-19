#!/usr/bin/env bash
# Render every experiment chart into results/charts/.
cd "$(dirname "$0")/.."
P=.venv/bin/python
c() { $P test/chart.py "$1" "results/charts/$2.png" "$4" --zero "$3" >/dev/null && echo "results/charts/$2.png"; }
c exp1-app-down          exp1  app-down       "Experiment 1: Frankfurt tasks stopped, clients keep their connections open"
c exp1b-app-down-newconn exp1b app-down       "Experiment 1b: same fault, a new connection per request"
c exp2a-fis-shallow      exp2a fis            "Experiment 2a: DynamoDB cut off in Frankfurt, shallow health check"
c exp2b-fis-deep         exp2b fis            "Experiment 2b: same fault, deep health check"
c exp3-rpo-b             exp3  app-down       "Experiment 3: replication paused, then Frankfurt lost"
c exp4-pilot-light       exp4  pilot-failover "Experiment 4: pilot light, Ireland starts from 0 tasks"
