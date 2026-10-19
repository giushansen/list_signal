import json, csv, os, re, numpy as np, pickle
from collections import Counter
S = os.path.dirname(os.path.abspath(__file__))
CLASSES = ["SaaS","Ecommerce","Agency","Consulting","LocalBusiness","Media","Education","Tool","Community","Marketplace","Newsletter","Directory","Government","Nonprofit","Manufacturer","FinancialInstitution","Junk"]
MAP = {"Bank":"FinancialInstitution","Insurance":"FinancialInstitution","Publishing":"Media"}
texts = {}
for f in ("train_texts.jsonl","v7_texts.jsonl"):
    for l in open(os.path.join(S,f)):
        r = json.loads(l); texts[r["domain"]] = r["text"]
train = {}
for l in open(os.path.join(S,"train_labels.jsonl")):
    r = json.loads(l); bm = MAP.get(r["business_model"], r["business_model"])
    if bm in CLASSES and r["domain"] in texts and len(texts[r["domain"]].strip()) > 20: train[r["domain"]] = bm
v7 = {}; v7_ind = {}
for r in csv.DictReader(open("analysis/golden_set/golden_set_v7_2026-10-19.csv")):
    d = r["domain"]; real = r["is_real_business"].strip().lower()
    t = "Junk" if real == "n" else MAP.get(r["true_model"].strip(), r["true_model"].strip())
    if t in CLASSES and d in texts and len(texts[d].strip()) > 20: v7[d] = t
    if real == "y" and r["true_industry"].strip() and d in texts: v7_ind[d] = r["true_industry"].strip()
train_d = sorted(train); v7_d = sorted(v7); all_d = train_d + v7_d
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
m = SentenceTransformer("intfloat/multilingual-e5-small", device="mps")
def evaluate(tag, E):
    X = E[:len(train_d)]; y = np.array([CLASSES.index(train[d]) for d in train_d]); Xg = E[len(train_d):]; yg = [v7[d] for d in v7_d]
    clf = make_pipeline(StandardScaler(), LogisticRegression(max_iter=4000, C=0.05, class_weight="balanced")).fit(X, y)
    P = clf.predict_proba(Xg); pred = [CLASSES[i] for i in P.argmax(1)]; conf = P.max(1)
    line = f"== {tag}: raw {np.mean([p==t for p,t in zip(pred,yg)]):.1%}"
    for thr in (0.5,0.7,0.8,0.9):
        k = conf >= thr; line += f" | >={thr} cov {k.mean():.0%} prec {np.mean([p==t for p,t,kk in zip(pred,yg,k) if kk]):.1%}"
    line += "\n   SaaS:"
    for thr in (0.6,0.7,0.8,0.9):
        idx=[i for i,p in enumerate(pred) if p=="SaaS" and conf[i]>=thr]; line += f" >={thr} {sum(1 for i in idx if yg[i]=='SaaS')}/{len(idx)}"
    line += "\n   per class >=0.7:" + " ".join(f"{c} {sum(1 for i,p in enumerate(pred) if p==c and conf[i]>=0.7 and yg[i]==c)}/{sum(1 for i,p in enumerate(pred) if p==c and conf[i]>=0.7)};" for c in CLASSES if any(p==c and conf[i]>=0.7 for i,p in enumerate(pred)))
    print(line, flush=True)
    return clf
for maxlen, chars in ((128, 500), (256, 1000)):
    m.max_seq_length = maxlen
    E = m.encode(["query: " + texts[d][:chars] for d in all_d], batch_size=32, normalize_embeddings=True, show_progress_bar=False)
    np.save(os.path.join(S, f"emb_e5_{maxlen}_{chars}.npy"), E)
    clf = evaluate(f"e5 maxlen={maxlen} chars={chars}", E)
    pickle.dump(clf, open(os.path.join(S, f"head_e5_{maxlen}_{chars}.pkl"), "wb"))
# industry calibration
src = open("lib/ls/ml/classifier.ex").read()
block = src[src.index("@industry_labels %{"):]
block = block[:block.index("\n  }\n")]
labels = {}
for mm in re.finditer(r'"([^"]+)" => \[(.*?)\]', block, re.S):
    labels[mm.group(1)] = re.findall(r'"([^"]+)"', mm.group(2))
print("industry labels:", len(labels), list(labels)[:5], flush=True)
mini = SentenceTransformer("sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2", device="mps"); mini.max_seq_length = 128
ind_d = [d for d in v7_d if d in v7_ind]
for tag, model, prefix, maxlen, chars in (("minilm", mini, "", 128, 500), ("e5", m, "query: ", 256, 1000)):
    model.max_seq_length = maxlen
    L = {}
    for name, descs in labels.items():
        e = model.encode([prefix + x for x in descs], normalize_embeddings=True); v = e.mean(0); L[name] = v / np.linalg.norm(v)
    T = model.encode([prefix + texts[d][:chars] for d in ind_d], batch_size=32, normalize_embeddings=True, show_progress_bar=False)
    names = list(L); M = np.stack([L[n] for n in names]); sims = T @ M.T
    best = sims.argmax(1); bs = sims.max(1)
    hits = np.array([names[b].lower() == v7_ind[d].lower() for b, d in zip(best, ind_d)])
    print(f"== industry {tag}: n={len(ind_d)} cosine p10/p50/p90 {np.percentile(bs,10):.3f}/{np.percentile(bs,50):.3f}/{np.percentile(bs,90):.3f}; raw exact-name acc {hits.mean():.1%}", flush=True)
    for q in (0, 25, 50, 75):
        thr = np.percentile(bs, q); k = bs >= thr
        print(f"   top {100-q}% (cos>={thr:.3f}): prec {hits[k].mean():.1%} n={k.sum()}", flush=True)
print("DONE", flush=True)
