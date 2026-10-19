import json, csv, sys, os, time, numpy as np
from collections import Counter
S = os.path.dirname(os.path.abspath(__file__))
CLASSES = ["SaaS","Ecommerce","Agency","Consulting","LocalBusiness","Media","Education","Tool","Community",
           "Marketplace","Newsletter","Directory","Government","Nonprofit","Manufacturer","FinancialInstitution","Junk"]
MAP = {"Bank":"FinancialInstitution","Insurance":"FinancialInstitution","Publishing":"Media"}
texts = {}
for f in ("train_texts.jsonl","v7_texts.jsonl"):
    for l in open(os.path.join(S,f)):
        r = json.loads(l); texts[r["domain"]] = r["text"]
train = {}
for l in open(os.path.join(S,"train_labels.jsonl")):
    r = json.loads(l); bm = MAP.get(r["business_model"], r["business_model"])
    if bm in CLASSES and r["domain"] in texts and len(texts[r["domain"]].strip()) > 20: train[r["domain"]] = bm
v7 = {}
for r in csv.DictReader(open("analysis/golden_set/golden_set_v7_2026-10-19.csv")):
    d = r["domain"]; real = r["is_real_business"].strip().lower()
    t = "Junk" if real == "n" else MAP.get(r["true_model"].strip(), r["true_model"].strip())
    if t in CLASSES and d in texts and len(texts[d].strip()) > 20: v7[d] = t
print(f"train {len(train)} v7 {len(v7)}; v7 dist {Counter(v7.values()).most_common()}", flush=True)
train_d = sorted(train); v7_d = sorted(v7)
all_d = train_d + v7_d
MODELS = [
  ("minilm", "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2", {}, "", 128, "mps"),
  ("e5small", "intfloat/multilingual-e5-small", {}, "query: ", 512, "mps"),
  ("bge-m3", "BAAI/bge-m3", {}, "", 512, "mps"),
  ("gte-base", "Alibaba-NLP/gte-multilingual-base", {"trust_remote_code": True}, "", 512, "cpu"),
]
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_score
import torch
results = {}
try:
    h = json.load(open("priv/ml/head_v3.json")); E = np.load(os.path.join(S, "emb_minilm.npy"))
    W = np.array(h["coef"]); b = np.array(h["intercept"]); Xg = E[len(train_d):]
    z = Xg @ W.T + b; P = np.exp(z - z.max(1, keepdims=True)); P /= P.sum(1, keepdims=True)
    hc = h["classes"]; pred = [hc[i] for i in P.argmax(1)]; conf = P.max(1); yg = [v7[d] for d in v7_d]
    print(f"shipped head_v3 on ST MiniLM embeddings: raw {np.mean([p==t for p,t in zip(pred,yg)]):.1%}; >=0.7 cov {(conf>=0.7).mean():.0%} prec {np.mean([p==t for p,t,k in zip(pred,yg,conf>=0.7) if k]):.1%}; >=0.95 cov {(conf>=0.95).mean():.0%}", flush=True)
    idx=[i for i,p in enumerate(pred) if p=="SaaS"]; print("  SaaS calls:", [(round(conf[i],2), yg[i]) for i in sorted(idx, key=lambda i:-conf[i])], flush=True)
except Exception as e: print("shipped head check failed", e)
for key, name, kw, prefix, maxlen, dev in MODELS:
    cache = os.path.join(S, f"emb_{key}.npy")
    if os.path.exists(cache):
        E = np.load(cache)
    else:
        t0 = time.time()
        m = SentenceTransformer(name, device=dev, **kw); m.max_seq_length = maxlen
        E = m.encode([prefix + texts[d][:4000] for d in all_d], batch_size=32, normalize_embeddings=True, show_progress_bar=False, convert_to_numpy=True)
        np.save(cache, E); print(f"{key}: embedded {len(all_d)} in {time.time()-t0:.0f}s dim {E.shape[1]}", flush=True)
        del m; torch.mps.empty_cache() if dev == "mps" else None
    X = E[:len(train_d)]; y = np.array([CLASSES.index(train[d]) for d in train_d])
    Xg = E[len(train_d):]; yg = [v7[d] for d in v7_d]
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    best = None
    for C in (0.05, 0.2, 1.0):
        cand = make_pipeline(StandardScaler(), LogisticRegression(max_iter=4000, C=C, class_weight="balanced"))
        s = cross_val_score(cand, X, y, cv=5).mean()
        print(f"  {key} C={C}: cv {s:.3f}", flush=True)
        if best is None or s > best[0]: best = (s, C, cand)
    cv, C, clf = best
    clf.fit(X, y)
    P = clf.predict_proba(Xg); pred = [CLASSES[i] for i in P.argmax(1)]; conf = P.max(1)
    acc = np.mean([p == t for p, t in zip(pred, yg)])
    line = f"\n== {key}  C={C} cv {cv:.3f}  v7 raw acc {acc:.1%} (n={len(yg)})"
    order = np.argsort(-conf)
    for frac in (0.2, 0.4, 0.6):
        k = int(len(yg) * frac); top = order[:k]
        line += f"\n  top {int(frac*100)}% by conf (n={k}): prec {np.mean([pred[i]==yg[i] for i in top]):.1%}, min conf {conf[top].min():.2f}"
    for thr in (0.5, 0.7, 0.8, 0.9, 0.95):
        keep = conf >= thr
        if keep.sum():
            a = np.mean([p == t for p, t, k in zip(pred, yg, keep) if k]); line += f"\n  conf>={thr}: cov {keep.mean():.0%} prec {a:.1%}"
    line += "\n  per class (pred -> correct/total at >=0.7):"
    for c in CLASSES:
        idx = [i for i, p in enumerate(pred) if p == c and conf[i] >= 0.7]
        if idx: line += f" {c} {sum(1 for i in idx if yg[i]==c)}/{len(idx)};"
    line += "\n  SaaS by floor:"
    for thr in (0.5, 0.7, 0.8, 0.9, 0.95):
        idx = [i for i, p in enumerate(pred) if p == "SaaS" and conf[i] >= thr]
        tot = sum(1 for t in yg if t == "SaaS")
        if idx: line += f" >={thr}: {sum(1 for i in idx if yg[i]=='SaaS')}/{len(idx)} calls, recall {sum(1 for i in idx if yg[i]=='SaaS')}/{tot};"
    line += "\n  recall by true class at >=0.7:"
    for c in CLASSES:
        tot = [i for i, t in enumerate(yg) if t == c]
        if tot: line += f" {c} {sum(1 for i in tot if pred[i]==c and conf[i]>=0.7)}/{len(tot)};"
    print(line, flush=True)
    results[key] = {"cv": cv, "acc": acc, "pred": pred, "conf": conf.tolist()}
    import pickle; pickle.dump(clf, open(os.path.join(S, f"head_{key}.pkl"), "wb"))
json.dump({k: {"cv": v["cv"], "acc": v["acc"]} for k, v in results.items()}, open(os.path.join(S, "bakeoff_summary.json"), "w"))
json.dump({"domains": v7_d, "truth": [v7[d] for d in v7_d], "preds": {k: {"pred": v["pred"], "conf": v["conf"]} for k, v in results.items()}}, open(os.path.join(S, "bakeoff_preds.json"), "w"))
print("DONE", flush=True)
