#!/usr/bin/env python3
"""Timeline chart for one run: successful requests per region and errors, per 5 s.
usage: chart.py <run> <out.png> "<title>" [--zero <event-name>]
Reads results/raw/<run>.jsonl and <run>.events (lines "<event> at <epoch-ms> ...").
"""
import json, re, sys, collections, argparse
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

ap = argparse.ArgumentParser(); ap.add_argument("run"); ap.add_argument("out"); ap.add_argument("title")
ap.add_argument("--zero", default=None); ap.add_argument("--bucket", type=int, default=5)
a = ap.parse_args()
base = f"results/raw/{a.run}"
rows = []
for line in open(base + ".jsonl"):
    m = re.search(r'msg="(\{.*\})"', line)
    if m:
        try: rows.append(json.loads(m.group(1).replace('\\"', '"')))
        except Exception: pass
events = []
for line in open(base + ".events"):
    m = re.match(r"(\S+) at (\d{13})", line)
    if m and m.group(1) != "snapshot": events.append((m.group(1), int(m.group(2))))
zero = dict(events).get(a.zero) if a.zero else None
zero = zero or rows[0]["t"]

B = a.bucket
buckets = collections.defaultdict(collections.Counter)
for r in rows:
    k = (r["t"] - zero) // 1000 // B * B
    buckets[k]["fra" if r["s"] == 201 and r["r"] == "eu-central-1" else "dub" if r["s"] == 201 else "err"] += 1
xs = sorted(buckets)
per_s = lambda key: [buckets[x][key] / B for x in xs]

plt.rcParams.update({"font.family": "Helvetica", "font.size": 12})
fig, ax = plt.subplots(figsize=(12, 4.6), dpi=150)
ax.stackplot(xs, per_s("fra"), per_s("dub"), per_s("err"), step="post",
             colors=["#2563eb", "#0f766e", "#dc2626"], alpha=0.9,
             labels=["OK from Frankfurt", "OK from Ireland", "Failed"])
labels = {"app-down": "Frankfurt tasks stopped", "app-up": "Frankfurt restored", "fis": "FIS: DynamoDB cut off",
          "pause-replication": "FIS: replication paused", "pilot-failover": "Frankfurt down +\nIreland scaled 0 to 1",
          "db-down": "IAM deny added", "db-up": "IAM deny removed", "noop": "", "fis-end": "FIS ends", "pause-end": "replication pause ends"}
shown = [(n, t) for n, t in events if n not in ("start", "noop")]
for i, (name, t) in enumerate(shown):
    x = (t - zero) / 1000
    ax.axvline(x, color="#111827", lw=1.2, ls="--")
    ax.text(x + 3, 13.4 if i % 2 == 0 else 11.6, labels.get(name, name), fontsize=10, va="top", color="#111827",
            bbox=dict(facecolor="white", edgecolor="none", pad=1.5))
ax.set_ylim(0, 13.8); ax.set_yticks([0, 2, 4, 6, 8, 10]); ax.set_xlim(xs[0], xs[-1] + B)
ax.set_ylabel("requests per second"); ax.set_xlabel("seconds" + (f" since: {labels.get(a.zero, a.zero)}" if a.zero else ""))
ax.set_title(a.title, loc="left", fontsize=14, fontweight="bold")
ax.spines[["top", "right"]].set_visible(False); ax.grid(axis="y", color="#e5e7eb")
ax.legend(loc="lower left", frameon=False, ncol=3, bbox_to_anchor=(0, -0.32))
fig.tight_layout(); fig.savefig(a.out); print(a.out)
