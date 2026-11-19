#!/usr/bin/env python3
"""ReplicationLatency (Frankfurt -> Ireland, max per minute) around experiment 3."""
import json, datetime as dt
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, matplotlib.dates as md
d = sorted(json.load(open("results/raw/exp3-replication-latency.json"))["Datapoints"], key=lambda p: p["Timestamp"])
ts = [dt.datetime.fromisoformat(p["Timestamp"]) for p in d]; ys = [p["Maximum"] / 1000 for p in d]
ev = {}
for line in open("results/raw/exp3-rpo-b.events"):
    p = line.split()
    if len(p) >= 3 and p[1] == "at" and p[2].isdigit(): ev[p[0]] = dt.datetime.fromtimestamp(int(p[2]) / 1000, dt.timezone.utc)
plt.rcParams.update({"font.family": "Helvetica", "font.size": 12})
fig, ax = plt.subplots(figsize=(12, 4), dpi=150)
# break the line where CloudWatch has no data points, instead of drawing across the gap
xs2, ys2 = [], []
for i, (t, y) in enumerate(zip(ts, ys)):
    if i and (t - ts[i - 1]).total_seconds() > 90: xs2.append(t - dt.timedelta(seconds=30)); ys2.append(float("nan"))
    xs2.append(t); ys2.append(y)
ax.plot(xs2, ys2, marker="o", color="#2563eb", lw=2)
ax.axvspan(ev["pause-replication"], ev["pause-end"], color="#fde68a", alpha=0.5, label="FIS replication pause (no data points)")
for k, label in [("app-down", "Frankfurt tasks stopped"), ("app-up", "Frankfurt restored")]:
    ax.axvline(ev[k], color="#111827", ls="--", lw=1.2); ax.text(ev[k], max(ys) * (0.92 if k == "app-down" else 0.6), " " + label, fontsize=10)
peak = max(range(len(ys)), key=lambda i: ys[i])
ax.annotate(f"backlog arrives: {ys[peak]:.0f} s behind", (ts[peak], ys[peak]), xytext=(15, -5), textcoords="offset points", fontsize=11)
ax.set_ylabel("replication latency, s (max/min)"); ax.xaxis.set_major_formatter(md.DateFormatter("%H:%M", tz=dt.timezone.utc))
ax.set_title("DynamoDB ReplicationLatency, Frankfurt to Ireland (normally ~1 s)", loc="left", fontsize=14, fontweight="bold")
ax.spines[["top", "right"]].set_visible(False); ax.grid(axis="y", color="#e5e7eb"); ax.legend(frameon=False, loc="upper left")
fig.tight_layout(); fig.savefig("results/charts/exp3-replication.png"); print("results/charts/exp3-replication.png")
