#!/bin/sh
"""": # sh runs these lines and hands over to Python; to Python they are an ignored string.
for py in python3 python py; do  # the first that really is Python 3.9+ (not, e.g., the Windows Store stub)
  "$py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null && exec "$py" "$0" "$@"
done
echo "pp: needs Python 3.9 or newer" >&2; exit 1
":"""
__doc__ = """pp - a plain-text paper library.

Each paper is one Markdown file in $PP_DIR (default ~/papers): YAML front matter
for metadata, Markdown for your notes. Metadata is fetched from arXiv,
Semantic Scholar and Crossref.

commands:
  add <arxiv-id|doi|url|title>...  fetch metadata, create files, print keys  [-s] [-t tag,...]
  ls                               list papers as TSV: key year star tags title  [-s] [-t tag]
  get <field> [key...]             print path, bib, url, notes, abstract or any front-matter field
  set <key> <field=value>...       star=true  tags+=a,b  tags-=a  notes+=...  builds_on+=<key>
  mv <key> <new-key>               rename a paper and every reference to it
  link                             fetch citations between your papers; fill in published venues
  graph                            serve the editable lineage page on 127.0.0.1  [-p port] [--no-open]
  graph -o <file.html>             write a read-only snapshot of it instead

Keys can be abbreviated to any unique prefix or substring of the key or title.
-s stars papers on `add` and lists only starred ones in `ls`.
`get` without keys prints the field for every paper. A value of - is read from stdin.

environment:
  PP_DIR       library folder (default ~/papers)
  S2_API_KEY   Semantic Scholar API key; optional, avoids rate limits
"""
import argparse, json, mimetypes, os, re, sys, threading, time, unicodedata, webbrowser, zlib
import urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from datetime import date
from html import unescape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "1.2.0"
LIB = Path(os.environ.get("PP_DIR") or "~/papers").expanduser()
TODAY = date.today().isoformat()
ORDER = ("title", "authors", "year", "venue", "arxiv", "doi", "s2", "url",
         "tags", "star", "added", "cites", "builds_on")
TEXT = {"title", "venue", "arxiv", "doi", "s2", "url"}  # never read these as numbers
SECTIONS = {"notes": "Notes"}  # body sections that `set` creates on demand
UA = f"pp/{VERSION} (+https://github.com/LarryLiZimo/pp-papers)"
S2 = "https://api.semanticscholar.org/graph/v1/paper/"
S2_FIELDS = "title,authors,year,venue,publicationVenue,externalIds,abstract"
CONFS = {"nips": "NeurIPS", "iclr": "ICLR", "icml": "ICML", "cvpr": "CVPR", "iccv": "ICCV",
         "eccv": "ECCV", "3dim": "3DV", "3dv": "3DV", "wacv": "WACV", "bmvc": "BMVC",
         "iros": "IROS", "icra": "ICRA", "rss": "RSS", "corl": "CoRL", "siggraph": "SIGGRAPH",
         "aaai": "AAAI", "ijcai": "IJCAI", "acl": "ACL", "emnlp": "EMNLP", "naacl": "NAACL",
         "ismar": "ISMAR"}
JOURNALS = {"tog": "TOG", "pami": "TPAMI", "ijcv": "IJCV", "ral": "RA-L", "trob": "T-RO",
            "ijrr": "IJRR", "jmlr": "JMLR", "tmlr": "TMLR"}
STOP = set("a an the on in of for to toward towards with and via from by is are do does "
           "what how why when can your our its at as into beyond".split())
LINK = re.compile(r"\]\(([^)\s]+)\)")  # markdown link targets


class Fail(Exception): pass
LOG = []  # warnings from the current operation; the web page shows them


def warn(msg): LOG.append(msg); print(f"pp: {msg}", file=sys.stderr)
def die(msg): raise Fail(msg)


# ---- file format: YAML front matter (the subset pp writes) + markdown body

def scalar(v):
    v = v.strip()
    try: return json.loads(v)
    except ValueError: pass
    v = re.sub(r"\s+#.*$", "", v)  # trailing comment
    try: return json.loads(v)
    except ValueError: pass
    if v.startswith("[") and v.endswith("]"):
        return [scalar(x) for x in v[1:-1].split(",") if x.strip()]
    if len(v) > 1 and v[0] == v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return v or None


def plain(s):
    if not re.fullmatch(r"\w[\w./+-]*(?:[ :][\w./+-]+)*", s): return False
    try: json.loads(s); return False  # would read back as a number / bool / null
    except ValueError: return True


def fmt(v):
    if isinstance(v, list) and all(isinstance(x, str) and plain(x) for x in v):
        return "[" + ", ".join(v) + "]"
    return v if isinstance(v, str) and plain(v) else json.dumps(v, ensure_ascii=False)


def parse(text):
    m = re.match(r"---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|$)", text, re.S)
    if not m: return {}, text
    meta, cur = {}, None
    for line in m[1].splitlines():
        s = line.strip()
        if not s or s.startswith("#"): continue
        if line[0] in " \t" and cur:  # nested block under the previous key
            if s.startswith("- "):
                meta[cur] = (meta[cur] if isinstance(meta[cur], list) else []) + [scalar(s[2:])]
            else:
                k, _, v = s.partition(":")
                meta[cur] = {**(meta[cur] if isinstance(meta[cur], dict) else {}), k.strip(): scalar(v)}
            continue
        k, _, v = line.partition(":")
        cur, val = k.strip(), scalar(v)
        if cur in TEXT and val is not None and not isinstance(val, str):
            val = re.sub(r"\s+#.*$", "", v).strip()  # e.g. an unquoted arXiv id read as a float
        meta[cur] = val
    return meta, text[m.end():]


def dump(meta, body):
    out = ["---"]
    for k in [k for k in ORDER if k in meta] + [k for k in meta if k not in ORDER]:
        v = meta[k]
        if v is None or v == "" or v == {} or (v == [] and k != "tags"): continue
        if isinstance(v, dict):
            out += [f"{k}:"] + [f"  {a}: {fmt(b)}" for a, b in v.items()]
        else:
            out.append(f"{k}: {fmt(v)}")
    return "\n".join(out) + "\n---\n" + body


def split_body(body):  # -> text before the first "## ", [[heading, text], ...]
    parts = re.split(r"^## +(.+?)[ \t]*$", body, flags=re.M)
    return parts[0], [[h, t] for h, t in zip(parts[1::2], parts[2::2])]


def section(body, field):  # "notes" matches "## Notes"
    return next((t.strip() for h, t in split_body(body)[1] if fold(h) == field), None)


def put_section(body, field, text):
    head, secs = split_body(body)
    new = f"\n\n{text}\n\n" if text else "\n\n\n"
    hit = next((s for s in secs if fold(s[0]) == field), None)
    if hit:
        hit[1] = new
    else:  # new sections go before the abstract
        i = next((i for i, s in enumerate(secs) if fold(s[0]) == "abstract"), len(secs))
        secs.insert(i, [SECTIONS.get(field, field), new])
    out = head
    for h, t in secs:
        out += ("" if not out or out.endswith("\n") else "\n") + f"## {h}{t}"
    return out


# ---- library

def papers():
    return {p.stem: parse(p.read_text(encoding="utf-8")) for p in sorted(LIB.glob("*.md"))}


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f: f.write(text)


def save(key, meta, body):
    LIB.mkdir(parents=True, exist_ok=True)
    write(LIB / f"{key}.md", dump(meta, body))


def resolve(key, lib):
    key = Path(key).stem if key.endswith(".md") else key
    if key in lib: return key
    hits = ([k for k in lib if k.startswith(key)] or [k for k in lib if key in k]  # "wang2025", "vggt"
            or [k for k, (m, _) in lib.items() if key.lower() in str(m.get("title") or "").lower()])  # "mast3r"
    if len(hits) == 1: return hits[0]
    die(f"{key}: " + (f"ambiguous ({' '.join(hits)})" if hits else "not in library"))


def lst(v): return v if isinstance(v, list) else [v] if v else []


def builds_on(m):  # [source key, ...]; pp 1.0 wrote {source key: reason}
    bo = m.get("builds_on")
    return list(bo) if isinstance(bo, dict) else lst(bo)


def year(m):
    try: return int(m.get("year"))
    except (TypeError, ValueError): return None


def url(m):
    if m.get("url"): return m["url"]
    if m.get("arxiv"): return f"https://arxiv.org/abs/{m['arxiv']}"
    if m.get("doi"): return f"https://doi.org/{m['doi']}"
    if m.get("s2"): return f"https://www.semanticscholar.org/paper/{m['s2']}"
    return ""


def fold(s):  # "Schönberger" -> "schonberger"
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", s)


def make_key(rec, lib):  # Google Scholar style: qi2017pointnet
    name = ((rec.get("authors") or ["anon"])[0].split() or ["anon"])[-1]
    word = next((w for w in map(fold, re.split(r"[\s:\-–]+", rec["title"])) if w and w not in STOP), "")
    key = base = f"{fold(name) or 'anon'}{rec.get('year') or ''}{word}"
    for c in "bcdefghijklmnopqrstuvwxyz":
        if key not in lib: break
        key = base + c
    return key


def find_dup(rec, lib):
    for k, (m, _) in lib.items():
        if any(rec.get(f) and str(m.get(f) or "").lower() == str(rec[f]).lower() for f in ("arxiv", "doi", "s2")):
            return k
        if fold(m.get("title") or "") == fold(rec["title"]):
            return k


# ---- metadata sources

def http(url, data=None, headers=None, tries=4):
    headers = {"User-Agent": UA, **(headers or {})}
    if data is not None:
        data, headers["Content-Type"] = json.dumps(data).encode(), "application/json"
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data, headers), timeout=30) as r:
                return r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            if e.code == 404: return None
            if (e.code not in (406, 429) and e.code < 500) or i == tries - 1: raise  # arXiv throttles with 406
        except (urllib.error.URLError, TimeoutError):
            if i == tries - 1: raise
        time.sleep(1.5 * 2 ** i)


def s2(path, data=None, tries=3):
    key = os.environ.get("S2_API_KEY")
    txt = http(S2 + path, data, {"x-api-key": key} if key else None, tries)
    return json.loads(txt) if txt else None


_arxiv_last = 0.0

def arxiv(aid):
    global _arxiv_last
    time.sleep(max(0.0, _arxiv_last + 3 - time.time()))  # arXiv asks for <= 1 request / 3 s
    _arxiv_last = time.time()
    try:
        xml = http("https://export.arxiv.org/api/query?id_list=" + urllib.parse.quote(aid), tries=1)
    except urllib.error.HTTPError:  # the API's CDN throttles bursts (406); the abs page is served separately
        return arxiv_page(aid)
    ns = {"a": "http://www.w3.org/2005/Atom", "x": "http://arxiv.org/schemas/atom"}
    e = ET.fromstring(xml).find("a:entry", ns) if xml else None
    if e is None or "api/errors" in e.findtext("a:id", "", ns): return None
    t = lambda tag: " ".join((e.findtext(tag, "", ns) or "").split())
    if not t("a:title"): return None
    return {"title": t("a:title"), "abstract": t("a:summary"), "doi": t("x:doi") or None,
            "authors": [" ".join(a.findtext("a:name", "", ns).split()) for a in e.findall("a:author", ns)],
            "year": int(t("a:published")[:4]) if t("a:published") else None}


def arxiv_page(aid):
    page = http(f"https://arxiv.org/abs/{aid}")
    tag = lambda n: [" ".join(unescape(x).split()) for x in
                     re.findall(rf'<meta name="citation_{n}" content="([^"]*)"', page or "")]
    if not tag("title"): return None
    return {"title": tag("title")[0], "abstract": (tag("abstract") or [""])[0], "doi": (tag("doi") or [None])[0],
            "authors": [" ".join(reversed(a.split(", ", 1))) for a in tag("author")],  # "Qi, Charles R."
            "year": int(tag("date")[0][:4]) if tag("date") else None}


def crossref(doi):
    txt = http("https://api.crossref.org/works/" + urllib.parse.quote(doi, safe="/"))
    if not txt: return None
    m = json.loads(txt)["message"]
    first = lambda k: (m.get(k) or [""])[0]
    return {"title": " ".join(re.sub(r"<[^>]+>", "", first("title")).split()),
            "authors": [" ".join(filter(None, (a.get("given"), a.get("family")))) for a in m.get("author", [])],
            "year": (m.get("issued", {}).get("date-parts") or [[None]])[0][0],
            "venue": first("short-container-title") or first("container-title") or None}


def ident(q):  # -> ("arxiv" | "doi" | "title", value)
    q, aid = q.strip(), r"(\d{4}\.\d{4,5}|[a-z][a-z.\-]*/\d{7})"
    m = re.search(r"arxiv\.org/(?:abs|pdf|html)/" + aid, q, re.I) or \
        re.fullmatch(r"(?:arxiv:)?" + aid + r"(?:v\d+)?", q, re.I)
    if m: return "arxiv", m[1]
    m = re.search(r"10\.\d{4,9}/[^\s\"<>]+", q)
    if m:
        doi = m[0].rstrip(".,;)")
        return ("arxiv", doi[15:]) if doi.lower().startswith("10.48550/arxiv.") else ("doi", doi)
    return "title", q


def s2_meta(p):
    """Semantic Scholar paper -> metadata dict, with the venue and year of the published version."""
    ids = p.get("externalIds") or {}
    rec = {"title": p.get("title"), "authors": [a["name"] for a in p.get("authors") or []],
           "year": p.get("year"), "venue": p.get("venue"), "abstract": p.get("abstract"),
           "arxiv": ids.get("ArXiv"), "doi": ids.get("DOI"), "s2": p.get("paperId")}
    pv = p.get("publicationVenue") or {}
    short = [n for n in [pv.get("name") or ""] + (pv.get("alternate_names") or [])
             if re.fullmatch(r"[A-Z][A-Za-z0-9-]{1,9}", n) and sum(c.isupper() for c in n) > 1]
    if short: rec["venue"] = short[0]  # "ECCV" rather than "European Conference on Computer Vision"
    # DBLP keys like conf/cvpr/QiSMG17 carry the venue and the *published* year (S2 often
    # gives the arXiv year). If it is far off, S2 merged a later reprint: distrust its ids.
    m = re.fullmatch(r"(conf|journals)/([\w-]+)/.*?(\d\d)[a-z]?", ids.get("DBLP") or "")
    if m and m[2] != "corr":
        yy = 2000 + int(m[3]) if 2000 + int(m[3]) <= date.today().year else 1900 + int(m[3])
        if not rec["year"] or abs(yy - rec["year"]) <= 1:
            rec["year"] = yy
            rec["venue"] = CONFS.get(m[2], m[2].upper()) if m[1] == "conf" else JOURNALS.get(m[2], rec["venue"])
        elif rec["arxiv"]:
            rec["doi"] = None
    if rec["venue"] in ("", "arXiv.org"): rec["venue"] = None
    return rec


def fetch(query):
    """arXiv id / DOI / URL / title -> metadata dict, or None."""
    kind, val = ident(query)
    rec, p = {}, None
    try:
        if kind == "title":
            hit = s2("search/match?fields=" + S2_FIELDS + "&query=" + urllib.parse.quote(val), tries=5)
            p = hit["data"][0] if hit and hit.get("data") else None
        else:
            p = s2(f"{'ARXIV' if kind == 'arxiv' else 'DOI'}:{val}?fields={S2_FIELDS}", tries=5)
    except Exception as e:
        warn(f"Semantic Scholar unavailable ({e}); venue left as arXiv until `pp link`")
    if p: rec = s2_meta(p)
    if kind == "arxiv": rec["arxiv"] = val
    if kind == "doi": rec["doi"] = rec.get("doi") or val
    if rec.get("arxiv"):
        try: a = arxiv(rec["arxiv"])
        except Exception as e: a = None; warn(f"arXiv unavailable ({e})")
        if a:  # arXiv's author list is authoritative; S2 sometimes mangles names
            rec.update(title=a["title"], authors=a["authors"], abstract=a["abstract"] or rec.get("abstract"))
            rec["year"] = rec.get("year") or a["year"]
            rec["doi"] = rec.get("doi") or a["doi"]
    elif rec.get("doi") and not p:
        try: rec.update({k: v for k, v in (crossref(rec["doi"]) or {}).items() if v})
        except Exception as e: warn(f"Crossref unavailable ({e})")
    if (rec.get("doi") or "").lower().startswith("10.48550/"): rec["doi"] = None  # arXiv's own DOI
    if rec.get("venue") in (None, "", "arXiv.org"): rec["venue"] = "arXiv" if rec.get("arxiv") else None
    return rec if rec.get("title") else None


# ---- operations, shared by the CLI and the web page

def add(q, star, tags, lib):
    rec = fetch(q)
    if not rec: die(f"{q}: not found (an arXiv id or DOI works best)")
    key = find_dup(rec, lib)
    if key:
        warn(f"{q}: already in library as {key}")
        return key
    key = make_key(rec, lib)
    meta = {f: rec.get(f) for f in ("title", "authors", "year", "venue", "arxiv", "doi")}
    if not (rec.get("arxiv") or rec.get("doi")): meta["s2"] = rec.get("s2")
    meta.update(tags=list(tags), star=True if star else None, added=TODAY)
    body = f"# {rec['title']}\n\n## Notes\n\n"
    if rec.get("abstract"): body += f"\n## Abstract\n\n{rec['abstract']}\n"
    save(key, meta, body)
    lib[key] = (meta, body)
    warn(f"added {key}: {rec['title']} ({' '.join(str(x) for x in (meta['venue'], meta['year']) if x)})")
    return key


def assign(key, pairs, lib):
    """Apply `field=value` assignments (see `set` in the help) to one paper and save it."""
    meta, body = lib[key]
    for kv in pairs:
        m = re.fullmatch(r"([\w.]+?)([+-]?)=(.*)", kv, re.S)
        if not m: die(f"bad assignment '{kv}' (use field=value, tags+=x, notes+=text, builds_on+=<key>)")
        f, op, v = m[1], m[2], m[3].strip()
        if f in SECTIONS or section(body, f) is not None:  # a body section: notes, abstract, ...
            if op == "-": die(f"{f}-= is not supported")
            if op == "+":
                if "\n" not in v and not re.match(r"([-*+>#|]|\d+[.)]\s|```)", v): v = "- " + v
                v = ((section(body, f) or "") + "\n" + v).strip()
            body = put_section(body, f, v)
        elif f in ("tags", "authors", "builds_on"):
            items, cur = [x.strip() for x in v.split(",") if x.strip()], lst(meta.get(f))
            if f == "builds_on":
                cur = builds_on(meta)
                items = [x if x in cur else resolve(x, lib) for x in items]  # a stale key can still be removed
                if key in items: die("a paper cannot build on itself")
            meta[f] = (list(dict.fromkeys(cur + items)) if op == "+"
                       else [x for x in cur if x not in items] if op == "-" else items)
        elif f == "star":
            if v not in ("true", "false"): die("star must be true or false")
            meta[f] = True if v == "true" else None
        else:
            meta[f] = int(v) if f == "year" and v.isdigit() else v or None
            if f == "title" and v: body = re.sub(r"^# .*$", lambda _: "# " + v, body, count=1, flags=re.M)
    save(key, meta, body)
    lib[key] = (meta, body)


def relink(lib, old, new):  # point every reference to `old` at `new`, or drop it (new=None)
    swap = lambda x: new if x == old else x
    for k, (m, body) in lib.items():
        bo = builds_on(m)
        if old in lst(m.get("cites")) or old in bo:
            m["cites"] = [swap(c) for c in lst(m.get("cites")) if new or c != old]
            m["builds_on"] = [swap(s) for s in bo if new or s != old]
            save(k, m, body)


def rename(old, new, lib):
    if not re.fullmatch(r"[\w.-]+", new) or new in lib: die(f"{new}: invalid or already taken")
    relink(lib, old, new)
    (LIB / f"{old}.md").rename(LIB / f"{new}.md")
    lib[new] = lib.pop(old)


def remove(key, lib):
    relink(lib, key, None)
    (LIB / f"{key}.md").unlink()
    del lib[key]


def link(lib):
    """Refresh `cites` between library papers from Semantic Scholar; returns the new (citer, cited) pairs."""
    ids = [(k, f"ARXIV:{m['arxiv']}" if m.get("arxiv") else f"DOI:{m['doi']}" if m.get("doi") else m.get("s2"))
           for k, (m, _) in lib.items()]
    ids = [(k, i) for k, i in ids if i]
    got, fields, new = [], "references.paperId,year,venue,publicationVenue,externalIds", []
    for j in range(0, len(ids), 500):
        got += s2("batch?fields=" + fields, {"ids": [i for _, i in ids[j:j + 500]]}, tries=6) or []
    known = {p["paperId"]: k for (k, _), p in zip(ids, got) if p}
    for (k, _), p in zip(ids, got):
        if not p: warn(f"{k}: not on Semantic Scholar"); continue
        meta, body = lib[k]
        old, cites = lst(meta.get("cites")), None
        if p.get("references"):  # else S2 has no reference list; keep what we had
            cites = sorted({known[r["paperId"]] for r in p["references"] if r.get("paperId") in known} - {k})
            new += [(k, c) for c in cites if c not in old]
            meta["cites"] = cites
        fill = s2_meta(p) if meta.get("venue") in (None, "", "arXiv") else {}
        if fill.get("venue"):  # published since `pp add`, or S2 was down then
            y0, y1 = str(meta.get("year")), str(fill["year"] or meta.get("year"))
            hint = f"  (rename: pp mv {k} {k.replace(y0, y1, 1)})" if y0 != y1 and y0 in k else ""
            warn(f"{k}: venue {fill['venue']} {y1}{hint}")
            meta.update(venue=fill["venue"], year=int(y1) if y1.isdigit() else meta.get("year"))
        if (cites is not None and cites != sorted(old)) or fill.get("venue"):
            save(k, meta, body)
    total = sum(len(lst(m.get("cites"))) for m, _ in lib.values())
    warn(f"{len(new)} new, {total} citation links among {len(lib)} papers")
    return new


# ---- the lineage page

def graph_data(lib, base=None):
    nodes, edges = [], []
    for k, (m, body) in lib.items():
        nodes.append({"id": k, "title": str(m.get("title") or k), "authors": list(map(str, lst(m.get("authors")))),
                      "year": year(m), "venue": str(m.get("venue") or ""), "star": m.get("star") is True,
                      "tags": list(map(str, lst(m.get("tags")))), "url": url(m),
                      "arxiv": m.get("arxiv"), "doi": m.get("doi"), "body": body})
        edges += [{"from": c, "to": k, "kind": "cites"} for c in lst(m.get("cites")) if c in lib and c != k]
        edges += [{"from": c, "to": k, "kind": "builds_on"} for c in builds_on(m) if c in lib and c != k]
    return {"nodes": nodes, "edges": edges, "base": base}


CODE = [Path(__file__).resolve(), Path(__file__).resolve().parent / "pp.html"]


def code_version():  # changes when pp or its page is updated on disk
    return [p.stat().st_mtime_ns for p in CODE]


def page(data, html=None):
    html = html or CODE[1].read_text(encoding="utf-8")
    return html.replace("/*DATA*/null", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))


def stamp():  # changes whenever a paper file is added, removed, renamed or edited
    files = "|".join(f"{p.name}:{p.stat().st_mtime_ns}" for p in sorted(LIB.glob("*.md")))
    return f"{zlib.crc32(files.encode()):08x}"


def local_file(target):  # a link target in the notes -> absolute path
    if target.lower().startswith("file:"):
        target = urllib.request.url2pathname(urllib.parse.urlparse(target).path)
    return (LIB / urllib.parse.unquote(target)).resolve()


def linked_files(lib):  # the only files the page may open: those your notes link to
    return {local_file(t) for _, body in lib.values() for t in LINK.findall(body)
            if not re.match(r"(https?|mailto):|#", t, re.I)}


def make_server(port):
    """A local server for the editable page. It reads the paper files on every request."""
    lock = threading.Lock()  # one write at a time
    # the page this code was written for; once pp is updated on disk, this server stops writing
    html, version = CODE[1].read_text(encoding="utf-8"), code_version()

    class Handler(BaseHTTPRequestHandler):
        timeout = 30
        def log_message(self, *_): pass

        def reply(self, code, body, ctype="application/json; charset=utf-8"):
            if not isinstance(body, (str, bytes)): body = json.dumps(body, ensure_ascii=False)
            data = body.encode("utf-8") if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def trusted(self):  # only our own page may talk to us: no DNS rebinding, no cross-site requests
            host, port = self.headers.get("Host", ""), self.server.server_address[1]
            return host in (f"127.0.0.1:{port}", f"localhost:{port}") and \
                self.headers.get("Origin") in (None, f"http://{host}")

        def do_GET(self):
            if not self.trusted(): return self.reply(403, {"error": "forbidden"})
            u = urllib.parse.urlparse(self.path)
            if u.path == "/":
                data = dict(graph_data(papers()), editable=True, stamp=stamp())
                return self.reply(200, page(data, html), "text/html; charset=utf-8")
            if u.path == "/api/data": return self.reply(200, graph_data(papers()))
            if u.path == "/api/stamp": return self.reply(200, {"stamp": stamp()})
            if u.path == "/file":
                p = local_file(urllib.parse.parse_qs(u.query).get("p", [""])[0])
                if p.is_file() and p in linked_files(papers()):
                    text = p.suffix.lower() in (".md", ".txt", ".bib", ".tex", ".py")
                    ctype = "text/plain; charset=utf-8" if text else mimetypes.guess_type(p.name)[0] or "application/octet-stream"
                    return self.reply(200, p.read_bytes(), ctype)
            self.reply(404, {"error": "not found"})

        def do_POST(self):
            if not self.trusted() or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                return self.reply(403, {"error": "forbidden"})
            if code_version() != version:  # old code could misread or damage files the new pp wrote
                return self.reply(409, {"error": "pp was updated after `pp graph` started, so this page no longer "
                                                 "saves changes. Restart it: Ctrl+C, then pp graph."})
            with lock: self.post()

        def post(self):
            LOG.clear()
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                lib, key = papers(), req.get("key")
                if self.path == "/api/add":
                    key = add(req["q"], bool(req.get("star")), req.get("tags", []), lib)
                elif self.path == "/api/set": assign(resolve(key, lib), req["pairs"], lib)
                elif self.path == "/api/mv": rename(resolve(key, lib), req["new"], lib); key = req["new"]
                elif self.path == "/api/rm": remove(resolve(key, lib), lib); key = None
                elif self.path == "/api/link": link(lib)
                else: return self.reply(404, {"error": "not found"})
                self.reply(200, {"data": graph_data(papers()), "key": key, "log": LOG, "stamp": stamp()})
            except Fail as e: self.reply(400, {"error": str(e), "log": LOG})
            except Exception as e: self.reply(500, {"error": f"{type(e).__name__}: {e}", "log": LOG})

    class Server(ThreadingHTTPServer):  # threads: browsers open idle preconnections that would block one loop
        allow_reuse_address = os.name != "nt"  # on Windows it would let two servers share a port
        daemon_threads = True

    return Server(("127.0.0.1", port), Handler)


def serve(port, open_browser):
    address = f"http://127.0.0.1:{port}/"
    try: srv = make_server(port)
    except OSError:
        warn(f"port {port} is busy (pp graph already running?); opening {address}")
        if open_browser: webbrowser.open(address)
        return 1
    warn(f"serving {LIB} at {address}  (Ctrl+C to stop)")
    if open_browser: webbrowser.open(address)
    try: srv.serve_forever()
    except KeyboardInterrupt: pass


# ---- commands

def cmd_add(a):
    lib, failed = papers(), 0
    for q in a.ids:
        try: print(add(q, a.star, [t.strip() for t in a.tags.split(",") if t.strip()], lib))
        except Fail as e: warn(str(e)); failed += 1
    return 1 if failed else 0


def cmd_ls(a):  # key order, like ls; pipe through sort for anything else
    for k, (m, _) in papers().items():
        if (a.star and m.get("star") is not True) or (a.tag and a.tag not in lst(m.get("tags"))): continue
        print("\t".join([k, str(year(m) or ""), "*" if m.get("star") is True else "",
                         ",".join(map(str, lst(m.get("tags")))), str(m.get("title") or "")]))


def bibtex(k, m):
    v = str(m.get("venue") or "")
    f = {"title": "{%s}" % (m.get("title") or ""), "author": " and ".join(map(str, lst(m.get("authors")))),
         "year": year(m)}
    if v in ("", "arXiv"): typ = "misc"
    elif v in CONFS.values() or re.search(r"conf|proc|symposium|workshop", v, re.I):
        typ, f["booktitle"] = "inproceedings", v
    else: typ, f["journal"] = "article", v
    if m.get("arxiv"): f.update(eprint=m["arxiv"], archivePrefix="arXiv")
    if m.get("doi"): f["doi"] = m["doi"]
    if typ == "misc" and not m.get("arxiv") and url(m): f["url"] = url(m)
    return f"@{typ}{{{k},\n" + ",\n".join(f"  {x} = {{{y}}}" for x, y in f.items() if y) + "\n}\n"


GETTERS = {"path": lambda k, m: str(LIB / f"{k}.md"), "url": lambda k, m: url(m), "bib": bibtex}


def value(k, meta, body, f):
    if f in GETTERS: return GETTERS[f](k, meta)
    if f in SECTIONS or section(body, f) is not None: return section(body, f) or ""
    v = builds_on(meta) if f == "builds_on" else meta.get(f)
    return ", ".join(map(str, v)) if isinstance(v, list) else "" if v is None else str(v)


def cmd_get(a):
    lib = papers()
    if not a.keys and a.field not in {*ORDER, *GETTERS, *SECTIONS, "abstract"} \
            and any(a.field in k for k in lib):
        die(f"usage: pp get <field> [key...]   e.g. pp get path {a.field}")
    keys = [resolve(k, lib) for k in a.keys] or list(lib)
    for k in keys:
        v = value(k, *lib[k], a.field)
        if not v: continue
        if len(keys) == 1 or a.field in GETTERS: print(v)  # a path, url or entry names its paper
        elif "\n" in v: print(f"==> {k} <==\n{v}\n")
        else: print(f"{k}\t{v}")


def cmd_set(a):
    lib = papers()
    pairs = [kv[:-1] + sys.stdin.read() if re.fullmatch(r"[\w.]+?[+-]?=-", kv) else kv for kv in a.pairs]
    assign(resolve(a.key, lib), pairs, lib)


def cmd_mv(a):
    lib = papers()
    rename(resolve(a.old, lib), a.new, lib)
    print(a.new)


def cmd_link(a):
    for k, c in link(papers()): print(f"{k}\t{c}")


def cmd_graph(a):
    if not a.output: return serve(a.port, not a.no_open)
    out = Path(a.output)
    try: base = Path(os.path.relpath(LIB, out.resolve().parent)).as_posix() + "/"
    except ValueError: base = LIB.resolve().as_uri() + "/"  # different drive
    write(out, page(graph_data(papers(), base)))
    print(out)


def main():
    for s in (sys.stdout, sys.stderr):  # never crash on a legacy console encoding; pipes get UTF-8
        s.reconfigure(errors="replace", **({} if s.isatty() else {"encoding": "utf-8"}))
    p = argparse.ArgumentParser(prog="pp", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=f"pp {VERSION}")
    sub = p.add_subparsers(dest="cmd", required=True, metavar="command")
    s = sub.add_parser("add", help="add papers by arXiv id, DOI, URL or title")
    s.add_argument("ids", nargs="+", metavar="id")
    s.add_argument("-s", "--star", action="store_true", help="star the papers")
    s.add_argument("-t", "--tags", default="", help="comma-separated")
    s = sub.add_parser("ls", help="list papers as TSV")
    s.add_argument("-s", "--star", action="store_true", help="only starred papers")
    s.add_argument("-t", "--tag")
    s = sub.add_parser("get", help="print a field: path, bib, url, notes, title, ...")
    s.add_argument("field")
    s.add_argument("keys", nargs="*", metavar="key")
    s = sub.add_parser("set", help="write fields: star=true tags+=x notes+=text builds_on+=<key>")
    s.add_argument("key")
    s.add_argument("pairs", nargs="+", metavar="field=value")
    s = sub.add_parser("mv", help="rename a paper and every reference to it")
    s.add_argument("old", metavar="key")
    s.add_argument("new", metavar="new-key")
    sub.add_parser("link", help="fetch citations between your papers from Semantic Scholar")
    s = sub.add_parser("graph", help="serve the editable lineage page (-o: write a snapshot)")
    s.add_argument("-o", "--output", metavar="file.html", help="write a read-only snapshot instead of serving")
    s.add_argument("-p", "--port", type=int, default=8421)
    s.add_argument("--no-open", action="store_true", help="don't open a browser")
    a = p.parse_args()
    try: sys.exit(globals()["cmd_" + a.cmd](a) or 0)
    except Fail as e: warn(str(e)); sys.exit(1)


if __name__ == "__main__":
    main()
