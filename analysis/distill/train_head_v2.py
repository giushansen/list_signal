#!/usr/bin/env python3
"""Head v2: 17-class logistic over MiniLM embeddings, trained on the merged
distill v1 (2,200) + v2 (~2,000) teacher labels; evaluated on the owner/golden
holdout including the classes v1 could not score (Government, Nonprofit,
Manufacturer, FinancialInstitution)."""
import json, sys
import numpy as np
from collections import Counter

emb_p, labels_p, golden_emb_p, golden_truth_p, out_p = sys.argv[1:6]

CLASSES = ["SaaS","Ecommerce","Agency","Consulting","LocalBusiness","Media",
           "Education","Tool","Community","Marketplace","Newsletter","Directory",
           "Government","Nonprofit","Manufacturer","FinancialInstitution","Junk"]
GOLDEN_MAP = {"Bank": "FinancialInstitution", "Insurance": "FinancialInstitution"}

emb = {}
for line in open(emb_p):
    r = json.loads(line); emb[r["domain"]] = np.array(r["embedding"], dtype=np.float32)

labels = {}
for line in open(labels_p):
    r = json.loads(line)
    bm = GOLDEN_MAP.get(r["business_model"], r["business_model"])
    if bm in CLASSES:
        labels[r["domain"]] = bm

X, y = [], []
for d, lbl in labels.items():
    if d in emb:
        X.append(emb[d]); y.append(CLASSES.index(lbl))
X = np.stack(X); y = np.array(y)
print(f"train: {len(y)}; dist: {Counter(CLASSES[i] for i in y).most_common()}")

from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_score
clf = LogisticRegression(max_iter=4000, C=2.0, class_weight="balanced")
cv = cross_val_score(clf, X, y, cv=5)
print(f"5-fold CV vs teacher: {cv.mean():.3f} +/- {cv.std():.3f}")
clf.fit(X, y)

g_emb = {}
for line in open(golden_emb_p):
    r = json.loads(line); g_emb[r["domain"]] = np.array(r["embedding"], dtype=np.float32)
g_truth = {}
for r in json.load(open(golden_truth_p)):
    t = GOLDEN_MAP.get(r["truth"], r["truth"])
    if t in CLASSES and r["domain"] in g_emb:
        g_truth[r["domain"]] = t

Xg = np.stack([g_emb[d] for d in g_truth]); yg = [g_truth[d] for d in g_truth]
proba = clf.predict_proba(Xg); pred = [CLASSES[i] for i in proba.argmax(1)]; conf = proba.max(1)
acc = np.mean([p == t for p, t in zip(pred, yg)])
print(f"\nGOLDEN HOLDOUT (n={len(yg)}): accuracy {acc:.1%}")
for thr in (0.0, 0.5, 0.6, 0.7):
    keep = conf >= thr
    if keep.sum():
        a = np.mean([p == t for p, t, k in zip(pred, yg, keep) if k])
        print(f"  conf>={thr}: coverage {keep.mean():.0%}  precision {a:.1%}")
print("\nper-class on holdout (pred -> correct/total):")
for c in CLASSES:
    idx = [i for i, p in enumerate(pred) if p == c]
    if idx:
        print(f"  {c:20s} {sum(1 for i in idx if yg[i]==c)}/{len(idx)}")
mis = [(d,t,p) for d,t,p in zip(list(g_truth), yg, pred) if t!=p]
print(f"\nmisses ({len(mis)}):", *(f"\n  {d}: owner={t} head={p}" for d,t,p in mis[:25]))

json.dump({"version":"head_v2_2026-08-17","model":"paraphrase-multilingual-MiniLM-L12-v2",
           "classes":CLASSES,"coef":clf.coef_.tolist(),"intercept":clf.intercept_.tolist()},
          open(out_p,"w"))
print(f"\nwrote {out_p}")
