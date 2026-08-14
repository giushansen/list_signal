#!/usr/bin/env python3
"""Revenue head: 5-bracket logistic over MiniLM embeddings.

Train on teacher gut brackets; hold out the 47 web-source-VERIFIED rows as
gold. Also score the current pipeline estimator on the same 47 for a fair
three-way comparison.
"""
import json, sys
import numpy as np
from collections import Counter

emb_p, labels_p, rows_p, out_p = sys.argv[1:5]
BRACKETS = ["<$1M", "$1M-$10M", "$10M-$100M", "$100M-$1B", "$1B+"]

emb = {json.loads(l)["domain"]: np.array(json.loads(l)["embedding"], dtype=np.float32)
       for l in open(emb_p)}
rows = {r["domain"]: r for r in json.load(open(rows_p))}

train, gold = [], []
for l in open(labels_p):
    r = json.loads(l)
    b = r.get("revenue_bracket", "")
    if b not in BRACKETS or r["domain"] not in emb:
        continue
    (gold if r.get("revenue_verified") else train).append((r["domain"], b))

print(f"train {len(train)} (teacher gut), gold holdout {len(gold)} (source-verified)")
print("train dist:", Counter(b for _, b in train).most_common())

X = np.stack([emb[d] for d, _ in train]); y = np.array([BRACKETS.index(b) for _, b in train])
from sklearn.linear_model import LogisticRegression
clf = LogisticRegression(max_iter=3000, C=2.0, class_weight="balanced")
clf.fit(X, y)

Xg = np.stack([emb[d] for d, _ in gold]); yg = [b for _, b in gold]
proba = clf.predict_proba(Xg); pred = [BRACKETS[i] for i in proba.argmax(1)]; conf = proba.max(1)

def adj(a, b):  # within one bracket
    return abs(BRACKETS.index(a) - BRACKETS.index(b)) <= 1

head_exact = np.mean([p == t for p, t in zip(pred, yg)])
head_adj = np.mean([adj(p, t) for p, t in zip(pred, yg)])

est_pairs = [(rows[d].get("estimated_revenue", ""), t) for (d, t) in gold if rows.get(d, {}).get("estimated_revenue", "") in BRACKETS]
est_exact = np.mean([p == t for p, t in est_pairs]) if est_pairs else 0
est_adj = np.mean([adj(p, t) for p, t in est_pairs]) if est_pairs else 0

print(f"\nON THE 47 SOURCE-VERIFIED ROWS (never trained on):")
print(f"  revenue head:      exact {head_exact:.0%}  within-one-bracket {head_adj:.0%}")
print(f"  current estimator: exact {est_exact:.0%}  within-one-bracket {est_adj:.0%}  (n={len(est_pairs)})")
for thr in (0.4, 0.5):
    keep = conf >= thr
    if keep.sum():
        e = np.mean([p == t for p, t, k in zip(pred, yg, keep) if k])
        a = np.mean([adj(p, t) for p, t, k in zip(pred, yg, keep) if k])
        print(f"  head conf>={thr}: coverage {keep.mean():.0%} exact {e:.0%} within-one {a:.0%}")

json.dump({"version": "revenue_head_v1_2026-08-15",
           "model": "paraphrase-multilingual-MiniLM-L12-v2",
           "classes": BRACKETS,
           "coef": clf.coef_.tolist(), "intercept": clf.intercept_.tolist()},
          open(out_p, "w"))
print(f"wrote {out_p}")
