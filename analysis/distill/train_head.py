#!/usr/bin/env python3
"""Train the logistic classification head on MiniLM embeddings + teacher labels.

Inputs:
  train_emb.jsonl   {"domain","embedding":[384]}   (teacher-labeled domains)
  labels.jsonl      {"domain","business_model",...} (consensus teacher labels)
  golden_emb.jsonl  {"domain","embedding":[384]}   (owner-labeled golden rows = holdout)
  golden_truth.json [{"domain","truth"}]

Outputs:
  head weights JSON {classes, coef (K x 384), intercept (K)} for the Elixir side
  eval report on the golden holdout (never trained on)
"""
import json, sys
import numpy as np
from collections import Counter

train_emb_p, labels_p, golden_emb_p, golden_truth_p, out_p = sys.argv[1:6]

CLASSES = ["SaaS","Ecommerce","Agency","Consulting","LocalBusiness","Media",
           "Education","Tool","Community","Marketplace","Newsletter","Directory","Junk"]

emb = {}
for line in open(train_emb_p):
    r = json.loads(line); emb[r["domain"]] = np.array(r["embedding"], dtype=np.float32)

labels = {}
for line in open(labels_p):
    r = json.loads(line)
    if r["business_model"] in CLASSES:
        labels[r["domain"]] = r["business_model"]

X, y = [], []
for d, lbl in labels.items():
    if d in emb:
        X.append(emb[d]); y.append(CLASSES.index(lbl))
X = np.stack(X); y = np.array(y)
print(f"train: {len(y)} examples; dist: {Counter(CLASSES[i] for i in y).most_common()}")

from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_score

clf = LogisticRegression(max_iter=3000, C=2.0, class_weight="balanced")
cv = cross_val_score(clf, X, y, cv=5)
print(f"5-fold CV accuracy vs teacher: {cv.mean():.3f} +/- {cv.std():.3f}")
clf.fit(X, y)

# golden holdout (owner labels, never trained on)
g_emb = {}
for line in open(golden_emb_p):
    r = json.loads(line); g_emb[r["domain"]] = np.array(r["embedding"], dtype=np.float32)
g_truth = {r["domain"]: r["truth"] for r in json.load(open(golden_truth_p))
           if r["truth"] in CLASSES and r["domain"] in g_emb}

Xg = np.stack([g_emb[d] for d in g_truth]); yg = [g_truth[d] for d in g_truth]
proba = clf.predict_proba(Xg)
pred = [CLASSES[i] for i in proba.argmax(1)]
conf = proba.max(1)

acc = np.mean([p == t for p, t in zip(pred, yg)])
print(f"\nGOLDEN HOLDOUT (owner labels, n={len(yg)}): accuracy {acc:.1%}")
for thr in (0.0, 0.5, 0.6, 0.7):
    keep = conf >= thr
    if keep.sum():
        a = np.mean([p == t for p, t, k in zip(pred, yg, keep) if k])
        print(f"  conf>={thr}: coverage {keep.mean():.0%}  precision {a:.1%}")
print("\nper-class on holdout:")
for c in CLASSES:
    idx = [i for i, p in enumerate(pred) if p == c]
    if idx:
        ok = sum(1 for i in idx if yg[i] == c)
        print(f"  {c:14s} {ok}/{len(idx)}")
mis = [(d, t, p) for d, t, p in zip(list(g_truth), yg, pred) if t != p]
print("\nholdout misses:", *(f"\n  {d}: owner={t} head={p}" for d, t, p in mis))

json.dump({"version": "head_v1_2026-08-14",
           "model": "paraphrase-multilingual-MiniLM-L12-v2",
           "classes": CLASSES,
           "coef": clf.coef_.tolist(),
           "intercept": clf.intercept_.tolist()},
          open(out_p, "w"))
print(f"\nwrote {out_p}")
