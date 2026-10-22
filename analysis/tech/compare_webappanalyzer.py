# Compare webappanalyzer fingerprints with our TechDetector on the 600 cached golden pages.
import json, glob, re, os, sys, collections
from urllib.parse import urlparse
S = os.path.dirname(os.path.abspath(__file__)); W = S + "/webappanalyzer/src"
cats = {k: v["name"] for k, v in json.load(open(W + "/categories.json")).items()}
techs = {}
for f in glob.glob(W + "/technologies/*.json"): techs.update(json.load(open(f)))
def pat(p):
    # strip wappalyzer "\;confidence:50\;version:..." suffixes
    p = p.split("\;")[0]
    try: return re.compile(p, re.I)
    except re.error: return None
def plist(v):
    v = v if isinstance(v, list) else [v]
    return [c for c in (pat(x) for x in v) if c]
comp = {}
for name, t in techs.items():
    comp[name] = {
        "script": plist(t.get("scriptSrc", [])), "html": plist(t.get("html", [])),
        "meta": {k.lower(): plist(v) for k, v in t.get("meta", {}).items()},
        "cats": [cats.get(str(c), str(c)) for c in t.get("cats", [])],
        "implies": t.get("implies", []) if isinstance(t.get("implies", []), list) else [t.get("implies")],
        "saas": t.get("saas"), "oss": t.get("oss"), "desc": (t.get("description") or "")[:120],
    }
# our detections per page from the harness dumps
ours = {}
for f in ("v6_cls_dump.jsonl", "v7_cls_dump.jsonl"):
    for l in open(S + "/" + f):
        r = json.loads(l); ours[r["domain"]] = [x for x in r["tech"].split("|") if x]
pages = {}
for d in ("pages_v6", "pages_v7"):
    for f in glob.glob(f"analysis/golden_set/{d}/*.html"):
        dom = os.path.basename(f)[:-5]
        if dom in ours: pages[dom] = open(f, "rb").read().decode("utf-8", "ignore")
print("pages", len(pages), flush=True)
src_re = re.compile(r"<script[^>]*\bsrc\s*=\s*[\"']([^\"']+)", re.I)
meta_re = re.compile(r"<meta\s+[^>]*>", re.I)
wa = {}; hosts = collections.Counter(); host_pages = collections.defaultdict(set)
for dom, html in pages.items():
    srcs = src_re.findall(html)
    metas = {}
    for m in meta_re.findall(html):
        n = re.search(r"\b(?:name|property)\s*=\s*[\"']([^\"']+)", m, re.I); c = re.search(r"\bcontent\s*=\s*[\"']([^\"']*)", m, re.I)
        if n and c: metas[n.group(1).lower()] = c.group(1)
    found = set()
    for name, c in comp.items():
        hit = any(p.search(s) for p in c["script"] for s in srcs) or any(p.search(html) for p in c["html"])
        if not hit:
            for k, ps in c["meta"].items():
                if k in metas and any(p.search(metas[k]) for p in ps): hit = True; break
        if hit: found.add(name)
    # implies closure
    changed = True
    while changed:
        changed = False
        for n in list(found):
            for imp in comp.get(n, {}).get("implies", []):
                imp = imp.split("\;")[0]
                if imp in comp and imp not in found: found.add(imp); changed = True
    wa[dom] = found
    for s in srcs:
        h = urlparse(s if s.startswith("http") else ("https:" + s if s.startswith("//") else "")).hostname
        if h and not h.endswith(dom) and dom.split(".")[0] not in h:
            hosts[h] += 1; host_pages[h].add(dom)
json.dump({d: sorted(v) for d, v in wa.items()}, open(S + "/wa_found.json", "w"))
# comparison
our_names = collections.Counter(n for v in ours.values() for n in v)
wa_names = collections.Counter(n for v in wa.values() for n in v)
our_set = set(json.load(open(S + "/our_catalog.json"))) if os.path.exists(S + "/our_catalog.json") else set(our_names)
print(f"avg techs/page ours {sum(len(v) for d,v in ours.items() if d in pages)/len(pages):.1f} vs webappanalyzer {sum(len(v) for v in wa.values())/len(pages):.1f}")
missing = [(n, c) for n, c in wa_names.most_common() if n not in our_set]
print(f"webappanalyzer names on these pages: {len(wa_names)}; not in our catalog: {len(missing)}")
print("\nTOP MISSED (name, pages, categories, saas):")
for n, c in missing[:80]:
    print(f"  {c:4d} {n:34s} {','.join(comp[n]['cats'])[:40]:42s} saas={comp[n]['saas']}")
print("\nOURS not in webappanalyzer (name, pages):", [(n, c) for n, c in our_names.most_common() if n not in comp][:40])
print("\nTHIRD-PARTY SCRIPT HOSTS not explained by any webappanalyzer scriptSrc pattern (host, pages):")
explained = set()
for dom, html in pages.items():
    for s in src_re.findall(html):
        h = urlparse(s if s.startswith("http") else ("https:" + s if s.startswith("//") else "")).hostname
        if h and any(p.search(s) for c in comp.values() for p in c["script"]): explained.add(h)
unk = [(h, len(host_pages[h])) for h, _ in hosts.most_common() if h not in explained]
for h, n in unk[:40]: print(f"  {n:3d} {h}")
print("DONE")
