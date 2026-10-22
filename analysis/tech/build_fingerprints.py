import json, glob, re, os, collections
S = os.path.dirname(os.path.abspath(__file__)); W = S + "/webappanalyzer/src"
cats = {k: v["name"] for k, v in json.load(open(W + "/categories.json")).items()}
techs = {}
for f in glob.glob(W + "/technologies/*.json"): techs.update(json.load(open(f)))
def norm(n): return re.sub(r"[^a-z0-9]", "", n.lower().replace(".js", "").replace("js", ""))
wa_n = {norm(n): n for n in techs}
ours = set(json.load(open(S + "/our_catalog.json"))); ours_n = {norm(n) for n in ours}
exec(open(S + "/wa_gen.py").read().split("WANT = [w.strip()")[0].split('WANT = """')[0])  # nothing
WANT = open(S + "/wa_gen.py").read().split('WANT = """')[1].split('""".replace')[0].replace("\n", "|").split("|")
WANT = [w.strip() for w in WANT if w.strip()]
ALIAS = {"Sendinblue": "Brevo", "Hubspot Chat": "HubSpot Chat", "Yandex.Metrika": "Yandex Metrica", "Baidu Analytics (百度统计)": "Baidu Analytics",
         "Kadence WP Kadence": "Kadence", "Linkedin Ads": "LinkedIn Ads", "Linkedin Sign-in": "LinkedIn Sign-in", "Bazaarvoice Reviews": "Bazaarvoice",
         "Avis Verifies": "Avis Vérifiés", "Hotjar Incoming Feedback": "Hotjar Feedback", "Sovrn//Commerce": "Sovrn Commerce", "DoubleClick for Publishers (DFP)": "Google Ad Manager",
         "Hyva Themes": "Hyvä", "Brizy WordPress": "Brizy", "Adobe Experience Platform Launch": "Adobe Launch", "Matomo Analytics": "Matomo", "Bolt Payments": "Bolt",
         "Heartland Payment Systems": "Heartland", "Framer Sites": "Framer", "GoDaddy Website Builder": "GoDaddy Builder", "Microsoft ASP.NET": "ASP.NET", "Auth0 Lock": "Auth0",
         "MagicLabs": "Magic", "Yotpo Loyalty & Referrals": "Yotpo Loyalty", "Cal.com": "Cal.com", "Google Ads Conversion Tracking": "Google Ads", "Amazon CloudFront": "CloudFront",
         "Buy me a coffee": "Buy Me a Coffee", "Unpkg": "unpkg", "Bunny": "BunnyCDN"}
OUR_CAT = {"CMS": "cms", "Ecommerce": "ecommerce", "Analytics": "analytics", "Marketing automation": "marketing", "Email": "marketing", "Personalisation": "marketing",
  "Retargeting": "ads", "Cart abandonment": "marketing", "Referral marketing": "marketing", "Live chat": "chat", "CRM": "crm", "Payment processors": "payments",
  "Buy now pay later": "payments", "Cookie compliance": "consent", "Security": "security", "Tag managers": "analytics", "Advertising": "ads", "Search engines": "search",
  "Page builders": "builder", "Hosting": "hosting", "PaaS": "hosting", "IaaS": "hosting", "Video players": "video", "Accessibility": "accessibility", "Translation": "translation",
  "Loyalty & rewards": "loyalty", "Reviews": "reviews", "Appointment scheduling": "booking", "Reservations & delivery": "booking", "Ticket booking": "booking",
  "Form builders": "forms", "Surveys": "forms", "Authentication": "auth", "A/B Testing": "ab_testing", "RUM": "performance", "Performance": "performance",
  "Recruitment & staffing": "hr", "LMS": "education", "Fundraising & donations": "donations", "Affiliate programs": "affiliate", "CDN": "cdn",
  "Web frameworks": "framework", "JavaScript frameworks": "framework", "UI frameworks": "framework", "JavaScript libraries": "library", "Static site generator": "cms",
  "Customer data platform": "analytics", "Feature management": "devtools", "Shipping carriers": "shipping", "Returns": "shipping", "Fulfilment": "shipping",
  "Documentation": "devtools", "Issue trackers": "devtools", "Message boards": "community", "Comment systems": "community", "Wikis": "community",
  "Digital asset management": "tools", "Livestreaming": "video", "User onboarding": "analytics", "Maps": "maps", "Font scripts": "library", "Widgets": "library",
  "WordPress plugins": "wordpress", "WordPress themes": "wordpress", "Shopify apps": "shopify", "Programming languages": "framework", "Web servers": "server",
  "Caching": "performance", "Databases": "framework", "Blogs": "cms", "Editors": "builder", "Miscellaneous": "tools", "Segmentation": "analytics", "Cross border ecommerce": "ecommerce",
  "Ecommerce frontends": "ecommerce", "Browser fingerprinting": "security", "SEO": "seo", "Geolocation": "tools", "Mobile frameworks": "framework", "Rich text editors": "library",
  "Photo galleries": "library", "JavaScript graphics": "library", "SSL/TLS certificate authorities": "security", "Domain parking": "hosting", "Webmail": "email", "Development": "devtools", "Containers": "devtools", "Reverse proxies": "server", "Load balancers": "server", "Media servers": "video"}
def strip(p): return p.split("\;")[0]
def plist(v):
    v = v if isinstance(v, list) else [v]
    out = []
    for x in v:
        x = strip(x)
        if not x: continue
        try: re.compile(x, re.I); out.append(x)
        except re.error: pass
    return out
fp = {}; unmatched = []
for w in WANT:
    n = wa_n.get(norm(w))
    if not n: unmatched.append(w); continue
    canon = ALIAS.get(n, n)
    if norm(canon) in ours_n or norm(n) in ours_n: continue   # we already publish it; keep our rules
    t = techs[n]
    e = {"source": "webappanalyzer", "wa_name": n, "cats": [cats.get(str(c), str(c)) for c in t.get("cats", [])],
         "script": plist(t.get("scriptSrc", [])), "meta": {k.lower(): plist(v) for k, v in t.get("meta", {}).items()},
         "headers": {k.lower(): plist(v) for k, v in t.get("headers", {}).items()}, "cookies": {k: plist(v) for k, v in t.get("cookies", {}).items()},
         "implies": [ALIAS.get(strip(x), strip(x)) for x in (t.get("implies", []) if isinstance(t.get("implies", []), list) else [t.get("implies")])],
         "saas": bool(t.get("saas")), "website": t.get("website"), "description": (t.get("description") or "")[:160]}
    for k in ("meta", "headers", "cookies"): e[k] = {kk: vv for kk, vv in e[k].items() if vv}
    if not (e["script"] or e["meta"] or e["headers"] or e["cookies"]): continue   # js/dom/dns-only: no strong evidence we can run
    e["category"] = next((OUR_CAT[c] for c in e["cats"] if c in OUR_CAT), "tools")
    e["ecosystem"] = "wordpress" if "WordPress plugins" in e["cats"] or "WordPress themes" in e["cats"] else ("shopify" if "Shopify apps" in e["cats"] else "")
    if e["category"] in ("cdn", "library", "tools", "server"): continue   # infrastructure noise, no buyer asks for it
    if n == "WebsiteBuilder": continue   # its generator pattern is the words "website builder", which Wix also writes
    def specific(pat):   # at least six literal characters including a dot, slash or dash: hostnames and paths, not words
        lit = re.sub(r"\\.|\[.*?\]|[\^$*+?(){}|]", "", pat)
        return len(lit) >= 6 and any(ch in lit for ch in "./-_")
    e["script"] = [x for x in e["script"] if specific(x)]
    e["meta"] = {k: [x for x in v if len(re.sub(r"[\^$*+?(){}|\\]", "", x)) >= 4] for k, v in e["meta"].items()}
    e["meta"] = {k: v for k, v in e["meta"].items() if v}
    e["cookies"] = {k: v for k, v in e["cookies"].items() if len(k) >= 5}
    if not (e["script"] or e["meta"] or e["headers"] or e["cookies"]): continue
    fp[canon] = e
# our own mined vendors (2026-10-22, third-party script hosts on 616 golden pages that no fingerprint explained)
MINED = {"Trustindex": ("reviews", r"cdn\.trustindex\.io/"), "TrustedSite": ("security", r"cdn\.trustedsite\.com/"), "Umami": ("analytics", r"cloud\.umami\.is/script\.js"),
         "CallRail": ("analytics", r"cdn\.callrail\.com/"), "Leadoo": ("chat", r"bot\.leadoo\.com/"), "Unbxd": ("search", r"libraries\.unbxdapi\.com/"),
         "CCM19": ("consent", r"cloud\.ccm19\.de/"), "CleanTalk": ("security", r"fd\.cleantalk\.org/"), "Hostinger Reach": ("marketing", r"cdn-reach\.hostinger\.com/"),
         "Vimeo": ("video", r"player\.vimeo\.com/api/player\.js")}
for n, (c, p) in MINED.items():
    if norm(n) in ours_n: continue
    fp[n] = {"source": "listsignal-mined", "cats": [], "script": [p], "meta": {}, "headers": {}, "cookies": {}, "implies": [], "saas": True, "category": c, "ecosystem": "", "description": ""}
json.dump(fp, open("priv/tech/fingerprints.json", "w"), indent=1, ensure_ascii=False)
npat = sum(len(e["script"]) + sum(len(v) for v in e["meta"].values()) + sum(len(v) for v in e["headers"].values()) + sum(len(v) for v in e["cookies"].values()) for e in fp.values())
print(f"fingerprints: {len(fp)} names, {npat} patterns; unmatched wanted names: {len(unmatched)}")
print("by category:", collections.Counter(e["category"] for e in fp.values()).most_common())
print("saas:", sum(1 for e in fp.values() if e["saas"]))
# hits on the 616 pages
ours_pages = {}
for f in ("v6_cls_dump.jsonl", "v7_cls_dump.jsonl"):
    for l in open(S + "/" + f):
        r = json.loads(l); ours_pages[r["domain"]] = [x for x in r["tech"].split("|") if x]
src_re = re.compile(r"<script[^>]*\bsrc\s*=\s*[\"']([^\"']+)", re.I); meta_re = re.compile(r"<meta\s+[^>]*>", re.I)
C = {n: {"script": [re.compile(p, re.I) for p in e["script"]], "meta": {k: [re.compile(p, re.I) for p in v] for k, v in e["meta"].items()}} for n, e in fp.items()}
hits = collections.Counter(); examples = collections.defaultdict(list); pages = 0; added = 0
for d in ("pages_v6", "pages_v7"):
    for f in glob.glob(f"analysis/golden_set/{d}/*.html"):
        dom = os.path.basename(f)[:-5]
        if dom not in ours_pages: continue
        html = open(f, "rb").read().decode("utf-8", "ignore"); pages += 1
        srcs = src_re.findall(html); metas = {}
        for m in meta_re.findall(html):
            nm = re.search(r"\b(?:name|property)\s*=\s*[\"']([^\"']+)", m, re.I); ct = re.search(r"\bcontent\s*=\s*[\"']([^\"']*)", m, re.I)
            if nm and ct: metas[nm.group(1).lower()] = ct.group(1)
        for n, c in C.items():
            ex = next((s for p in c["script"] for s in srcs if p.search(s)), None)
            if not ex:
                for k, ps in c["meta"].items():
                    if k in metas and any(p.search(metas[k]) for p in ps): ex = f"meta {k}={metas[k][:40]}"; break
            if ex: hits[n] += 1; added += 1; examples[n].append((dom, ex[:70]))
print(f"\npages {pages}: new detections {added} ({added/pages:.2f} per page); names hit: {len(hits)}")
for n, c in hits.most_common(45): print(f"  {c:3d} {n:28s} {fp[n]['category']:12s} e.g. {examples[n][0][0]} <- {examples[n][0][1]}")
json.dump({"hits": hits, "examples": {n: v[:3] for n, v in examples.items()}}, open(S + "/fp_hits.json", "w"))
