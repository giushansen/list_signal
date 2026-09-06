#!/usr/bin/env python3
"""Head v3 (2026-09-06): 17-class logistic over MiniLM embeddings of
`title h1 meta body + LS.ML.Features hint`, trained on the merged distill
v1 + v2 + v3 teacher labels, evaluated on the golden holdouts (v3, v4, v5
truth). Usage:

  python3 train_head_v3.py EMB.jsonl LABELS.jsonl GOLDEN_EMB.jsonl GOLDEN_TRUTH.json OUT.json

Same contract as train_head_v2.py (the embedding script now appends the
hint, so both files must have been produced AFTER that change)."""
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
g_truth, g_src = {}, {}
for r in json.load(open(golden_truth_p)):
    t = GOLDEN_MAP.get(r["truth"], r["truth"])
    if t in CLASSES and r["domain"] in g_emb:
        g_truth[r["domain"]] = t; g_src[r["domain"]] = r.get("set", "?")
Xg = np.stack([g_emb[d] for d in g_truth]); yg = [g_truth[d] for d in g_truth]
proba = clf.predict_proba(Xg); pred = [CLASSES[i] for i in proba.argmax(1)]; conf = proba.max(1)
acc = np.mean([p == t for p, t in zip(pred, yg)])
print(f"\nGOLDEN HOLDOUT (n={len(yg)}): accuracy {acc:.1%}")
for thr in (0.0, 0.5, 0.6, 0.7):
    keep = conf >= thr
    if keep.sum():
        a = np.mean([p == t for p, t, k in zip(pred, yg, keep) if k])
        print(f"  conf>={thr}: coverage {keep.mean():.0%}  precision {a:.1%}")
print("\nper golden set:")
for s in sorted(set(g_src.values())):
    idx = [i for i, d in enumerate(g_truth) if g_src[d] == s]
    if idx:
        a = np.mean([pred[i] == yg[i] for i in idx])
        print(f"  {s}: n={len(idx)} accuracy {a:.1%}")
print("\nper-class on holdout (pred -> correct/total):")
for c in CLASSES:
    idx = [i for i, p in enumerate(pred) if p == c]
    if idx:
        print(f"  {c:20s} {sum(1 for i in idx if yg[i]==c)}/{len(idx)}")
json.dump({"version":"head_v3_2026-09-06","model":"paraphrase-multilingual-MiniLM-L12-v2",
           "text":"title h1 meta body + LS.ML.Features.hint","classes":CLASSES,
           "coef":clf.coef_.tolist(),"intercept":clf.intercept_.tolist()},
          open(out_p,"w"))
print(f"\nwrote {out_p}")
