"""Score PADS tasks with NeuroSense and summarise by diagnosis.

Run from backend/: PYTHONPATH=. python -I ../scripts/eval_pads.py <pads_dir> [Task ...]
PADS: 100 Hz, columns Time, Acc XYZ (g), Gyro XYZ. Reads only, writes nothing.
"""
import collections
import glob
import json
import os
import sys

import numpy as np

from app.sense.score import score_window

FS = 100.0
root = sys.argv[1]
tasks = sys.argv[2:] or ["Relaxed", "StretchHold"]

cond = {}
for f in glob.glob(os.path.join(root, "patients", "patient_*.json")):
    d = json.load(open(f))
    cond[d["id"]] = d["condition"]

rows = collections.defaultdict(list)
for task in tasks:
    for sid, c in cond.items():
        for wrist in ("LeftWrist", "RightWrist"):
            p = os.path.join(root, "movement", "timeseries", f"{sid}_{task}_{wrist}.txt")
            if not os.path.exists(p):
                continue
            x = np.loadtxt(p, delimiter=",")
            rows[(task, c)].append(score_window(x[:, 1:4], FS))

print(f"{'task':12} {'condition':26} {'n':>4} {'refused%':>9} {'med score':>10} {'p90 score':>10} {'med Hz':>7}")
for (task, c), rs in sorted(rows.items()):
    ok = [r for r in rs if r.status == "ok"]
    sc = [r.tremor_score for r in ok]
    hz = [r.dominant_hz for r in ok]
    refused = 100 * (len(rs) - len(ok)) / len(rs)
    print(f"{task:12} {c:26} {len(rs):4d} {refused:9.1f} "
          f"{np.median(sc) if sc else float('nan'):10.1f} {np.percentile(sc, 90) if sc else float('nan'):10.1f} "
          f"{np.median(hz) if hz else float('nan'):7.2f}")
reasons = collections.Counter(r.reason for rs in rows.values() for r in rs if r.status != "ok")
print("refusal reasons:", dict(reasons))
