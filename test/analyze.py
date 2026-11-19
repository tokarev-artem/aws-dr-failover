#!/usr/bin/env python3
"""Timeline, recovery time and data loss for one run.
usage: analyze.py results/raw/<run>.jsonl [--fault-at <epoch-ms>] [--check-region eu-west-1]
"""
import json, sys, re, argparse, collections, subprocess, os

ap = argparse.ArgumentParser()
ap.add_argument("log"); ap.add_argument("--fault-at", type=int); ap.add_argument("--check-region")
ap.add_argument("--bucket", type=int, default=5)
ap.add_argument("--undo-at", type=int)
a = ap.parse_args()

rows = []
for line in open(a.log):
    m = re.search(r'msg="(\{.*\})"', line)   # k6 wraps console.log in logfmt
    raw = m.group(1).replace('\\"', '"') if m else line.strip()
    try: rows.append(json.loads(raw))
    except Exception: pass
rows.sort(key=lambda r: r["t"])
t0 = rows[0]["t"]; fault = a.fault_at
ok = lambda r: r["s"] == 201

print(f"requests: {len(rows)}  ok: {sum(map(ok, rows))}  failed: {sum(not ok(r) for r in rows)}")
print(f"\n{'t(s)':>6}  {'ok '+'eu-central-1':>16} {'ok eu-west-1':>13} {'errors':>7}   (bucket {a.bucket}s, t=0 at {'fault' if fault else 'start'})")
base = fault or t0
b = collections.OrderedDict()
for r in rows:
    k = (r["t"] - base) // 1000 // a.bucket * a.bucket
    c = b.setdefault(k, collections.Counter())
    c[r["r"] if ok(r) else "err"] += 1
for k, c in b.items():
    if c["err"] or k % 30 == 0 or (fault and -10 <= k <= 200):
        print(f"{k:>6}  {c['eu-central-1']:>16} {c['eu-west-1']:>13} {c['err']:>7}")

if fault:
    after = [r for r in rows if r["t"] >= fault]
    errs = [r for r in after if not ok(r)]
    first_err = errs[0]["t"] if errs else None
    # recovered = first success after which the next 30 s have no server errors (5xx) and >= 97% ok.
    # Status 0 = client-side timeout; the laptop produces ~1-2% of those even when nothing is broken.
    rec = None
    for i, r in enumerate(after):
        if not ok(r) or (first_err and r["t"] < first_err): continue
        win = [x for x in after[i:] if x["t"] < r["t"] + 30000]
        if win[-1]["t"] - r["t"] > 25000 and not any(x["s"] >= 500 for x in win) and sum(map(ok, win)) >= 0.97 * len(win):
            rec = r; break
    print(f"\nfirst error after fault: {(first_err - fault)/1000 if first_err else '-'} s")
    print(f"recovered (30 s, >=97% ok):  {(rec['t'] - fault)/1000 if rec else 'never'} s, served by {rec['r'] if rec else '-'}")
    print(f"failed requests after fault: {len(errs)}  ({collections.Counter(str(e['s'])+(' '+str(e['e']) if e['e'] else '') for e in errs).most_common(5)})")

if a.undo_at:
    after = [r for r in rows if r["t"] >= a.undo_at]
    back = next((r for r in after if r["r"] == "eu-central-1" and r["s"] == 201), None)
    errs = [r for r in after if r["s"] != 201]
    print(f"\nfailback: first request served by eu-central-1 again after {(back['t']-a.undo_at)/1000 if back else 'never'} s; errors during failback: {len(errs)}")

if a.check_region:
    run = os.path.basename(a.log).rsplit(".", 1)[0]
    acked = {r["seq"] for r in rows if ok(r)}
    seen, key = set(), None
    while True:
        cmd = ["aws", "dynamodb", "query", "--region", a.check_region, "--table-name", "dr-demo",
               "--key-condition-expression", "pk = :p", "--expression-attribute-values", json.dumps({":p": {"S": f"run#{run}"}}),
               "--projection-expression", "sk", "--consistent-read", "--output", "json"]
        if key: cmd += ["--exclusive-start-key", json.dumps(key)]
        out = json.loads(subprocess.check_output(cmd))
        seen |= {int(i["sk"]["N"]) for i in out["Items"]}
        key = out.get("LastEvaluatedKey")
        if not key: break
    lost = sorted(acked - seen)
    print(f"\nacknowledged writes: {len(acked)}  present in {a.check_region}: {len(acked & seen)}  missing: {len(lost)}")
    if lost: print(f"missing seq range: {lost[0]}..{lost[-1]}")
