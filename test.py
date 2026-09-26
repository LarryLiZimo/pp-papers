#!/usr/bin/env python3
"""Offline tests for pp. Run: python test.py"""
import argparse, io, json, os, shutil, tempfile, threading, unittest, urllib.error, urllib.request
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path

TMP = Path(tempfile.mkdtemp())
os.environ["PP_DIR"] = str(TMP / "papers")  # set before loading pp, which reads it once
loader = SourceFileLoader("pp", str(Path(__file__).resolve().parent / "pp"))
pp = module_from_spec(spec_from_loader("pp", loader))
loader.exec_module(pp)
pp.warn = pp.LOG.append  # keep test output quiet

ATOM = """<feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom"><entry>
<id>http://arxiv.org/abs/1612.00593v2</id><published>2016-12-02T17:00:00Z</published>
<title>PointNet: Deep Learning on Point Sets
  for 3D Classification and Segmentation</title><summary>Point cloud is an important type of data.</summary>
<author><name>Charles R. Qi</name></author><author><name>Hao Su</name></author></entry></feed>"""
S2_POINTNET = {"paperId": "d997", "title": "PointNet", "year": 2016, "abstract": None,
               "venue": "Computer Vision and Pattern Recognition",
               "publicationVenue": {"name": "Computer Vision and Pattern Recognition", "alternate_names": ["CVPR"]},
               "externalIds": {"ArXiv": "1612.00593", "DBLP": "conf/cvpr/QiSMG17", "DOI": "10.1109/CVPR.2017.16"},
               "authors": [{"name": "R. Charles"}, {"name": "Hao Su"}]}


def paper(key, title, year=2020, body="", **meta):
    pp.save(key, {"title": title, "authors": ["Ada Lovelace"], "year": year, "tags": [], "status": "queue", **meta},
            f"# {title}\n\n## TL;DR\n\n\n## Notes\n\n{body}\n## Abstract\n\nAn abstract.\n")


def reset():
    shutil.rmtree(pp.LIB, ignore_errors=True)
    paper("old2016base", "Base Method", 2016)
    paper("new2020next", "Next Method: Better", 2020, cites=["old2016base"],
          builds_on={"old2016base": "adds X to the base"}, body="- see [write-up](../write-up.md)\n")
    (TMP / "write-up.md").write_text("my write-up", encoding="utf-8")
    (TMP / "secret.txt").write_text("not linked", encoding="utf-8")


def run(fn, **kw):
    out = io.StringIO()
    with redirect_stdout(out): fn(argparse.Namespace(**kw))
    return out.getvalue()


class Format(unittest.TestCase):
    def test_roundtrip(self):
        meta = {"title": "A: B #1", "authors": ["Charles R. Qi", "O'Brien, Jr."], "year": 2017, "venue": "CVPR",
                "arxiv": "2001.01230", "doi": "10.1109/CVPR.2017.16", "tags": [], "status": "read",
                "read": "2026-09-25", "cites": ["x2016y"], "builds_on": {"x2016y": "把 A 变成 B: # not a comment"}}
        self.assertEqual(pp.parse(pp.dump(meta, "# T\n\nbody\n")), (meta, "# T\n\nbody\n"))

    def test_hand_written_yaml(self):
        m, body = pp.parse("---\ntitle: Foo: Bar\narxiv: 1612.00593  # a comment\nyear: 2017\n"
                           "tags:\n  - nerf\n  - 3d\ncites: [a, b]\n---\nbody")
        self.assertEqual(m, {"title": "Foo: Bar", "arxiv": "1612.00593", "year": 2017,
                             "tags": ["nerf", "3d"], "cites": ["a", "b"]})
        self.assertEqual(body, "body")

    def test_ident(self):
        for q, want in [("1612.00593", ("arxiv", "1612.00593")), ("arXiv:1612.00593v2", ("arxiv", "1612.00593")),
                        ("https://arxiv.org/pdf/1612.00593v2.pdf", ("arxiv", "1612.00593")),
                        ("10.48550/arXiv.1706.03762", ("arxiv", "1706.03762")), ("hep-th/9901001", ("arxiv", "hep-th/9901001")),
                        ("https://doi.org/10.1109/CVPR.2016.445", ("doi", "10.1109/CVPR.2016.445")),
                        ("Structure-from-Motion Revisited", ("title", "Structure-from-Motion Revisited"))]:
            self.assertEqual(pp.ident(q), want, q)

    def test_key(self):
        rec = {"authors": ["Johannes L. Schönberger"], "year": 2016, "title": "Structure-from-Motion Revisited"}
        self.assertEqual(pp.make_key(rec, {}), "schonberger2016structure")
        self.assertEqual(pp.make_key(rec, {"schonberger2016structure": None}), "schonberger2016structureb")


class Fetch(unittest.TestCase):
    def setUp(self):
        self.s2, self.real = S2_POINTNET, pp.http
        pp.http, pp._arxiv_last = self.fake, -1e9

    def tearDown(self):
        pp.http = self.real

    def fake(self, url, data=None, headers=None, tries=4):
        if "export.arxiv.org" in url: return ATOM
        if "semanticscholar" in url:
            if self.s2 is None: raise urllib.error.HTTPError(url, 429, "Too Many Requests", {}, None)
            return json.dumps(self.s2)
        raise AssertionError(url)

    def test_merge(self):  # authors from arXiv, venue and published year from DBLP
        rec = pp.fetch("1612.00593")
        self.assertEqual(rec["title"], "PointNet: Deep Learning on Point Sets for 3D Classification and Segmentation")
        self.assertEqual((rec["authors"][0], rec["venue"], rec["year"], rec["doi"]),
                         ("Charles R. Qi", "CVPR", 2017, "10.1109/CVPR.2017.16"))

    def test_reprint(self):  # S2 merged a later journal reprint: keep its year, drop the reprint's DOI
        self.s2 = {**S2_POINTNET, "year": 2020, "externalIds": {**S2_POINTNET["externalIds"], "DBLP": "journals/cacm/QiX22"}}
        rec = pp.fetch("1612.00593")
        self.assertEqual((rec["year"], rec["doi"]), (2020, None))

    def test_s2_down(self):
        self.s2 = None
        rec = pp.fetch("1612.00593")
        self.assertEqual((rec["venue"], rec["year"], rec["authors"][0]), ("arXiv", 2016, "Charles R. Qi"))


class Library(unittest.TestCase):
    def setUp(self): reset()

    def test_resolve(self):
        lib = pp.papers()
        for q, want in [("old", "old2016base"), ("2020next", "new2020next"), ("better", "new2020next")]:
            self.assertEqual(pp.resolve(q, lib), want)
        self.assertRaises(pp.Fail, pp.resolve, "20", lib)  # ambiguous
        self.assertRaises(pp.Fail, pp.resolve, "nope", lib)

    def test_sections(self):
        lib = pp.papers()
        pp.assign("old2016base", ["tldr=One line.", "notes+=first", "notes+=- second", "notes+=third"], lib)
        body = pp.papers()["old2016base"][1]
        self.assertEqual(pp.section(body, "tldr"), "One line.")
        self.assertEqual(pp.section(body, "notes"), "- first\n- second\n- third")
        self.assertEqual(pp.section(body, "abstract"), "An abstract.")
        pp.assign("old2016base", ["notes="], lib)
        self.assertEqual(pp.section(pp.papers()["old2016base"][1], "notes"), "")

    def test_fields(self):
        lib = pp.papers()
        pp.assign("old2016base", ["tags=a,b", "tags+=c", "tags-=a", "status=read", "year=2017", "title=Renamed"], lib)
        m, body = pp.papers()["old2016base"]
        self.assertEqual((m["tags"], m["status"], m["read"], m["year"]), (["b", "c"], "read", pp.TODAY, 2017))
        self.assertTrue(body.startswith("# Renamed\n"))
        self.assertRaises(pp.Fail, pp.assign, "old2016base", ["status=done"], lib)
        self.assertRaises(pp.Fail, pp.assign, "old2016base", ["builds_on.old=self"], lib)

    def test_builds_on(self):
        lib = pp.papers()
        pp.assign("new2020next", ["builds_on.old=new reason"], lib)
        self.assertEqual(pp.papers()["new2020next"][0]["builds_on"], {"old2016base": "new reason"})
        pp.assign("new2020next", ["builds_on.old="], lib)
        self.assertNotIn("builds_on", pp.papers()["new2020next"][0])

    def test_rename_and_remove(self):
        lib = pp.papers()
        pp.rename("old2016base", "old2017base", lib)
        m = pp.papers()["new2020next"][0]
        self.assertEqual((m["cites"], m["builds_on"]), (["old2017base"], {"old2017base": "adds X to the base"}))
        pp.remove("old2017base", lib)
        self.assertEqual(list(pp.papers()), ["new2020next"])
        self.assertFalse({"cites", "builds_on"} & set(pp.papers()["new2020next"][0]))

    def test_get(self):
        self.assertEqual(run(pp.cmd_get, field="title", keys=["old"]), "Base Method\n")
        self.assertEqual(run(pp.cmd_get, field="year", keys=[]), "new2020next\t2020\nold2016base\t2016\n")  # key order
        self.assertIn("@misc{old2016base,", run(pp.cmd_get, field="bib", keys=["old"]))
        self.assertEqual(run(pp.cmd_ls, status=None, tag=None).splitlines()[1].split("\t")[:3],
                         ["old2016base", "2016", "queue"])

    def test_graph_data(self):
        g = pp.graph_data(pp.papers())
        self.assertEqual(sorted((e["kind"], e["from"], e["to"]) for e in g["edges"]),
                         [("builds_on", "old2016base", "new2020next"), ("cites", "old2016base", "new2020next")])


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        reset()
        cls.srv = pp.make_server(0)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def req(self, path, body=None, **headers):
        data = json.dumps(body).encode() if body is not None else None
        if data: headers.setdefault("Content-Type", "application/json")
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data, headers)
        try:
            with urllib.request.urlopen(r, timeout=10) as res: return res.status, res.read().decode()
        except urllib.error.HTTPError as e: return e.code, e.read().decode()

    def test_page_and_edit(self):
        code, html = self.req("/")
        self.assertEqual(code, 200)
        self.assertIn('"editable": true', html)
        code, res = self.req("/api/set", {"key": "old", "pairs": ["notes+=from the page"]})
        self.assertEqual(code, 200)
        self.assertEqual(pp.section(pp.papers()["old2016base"][1], "notes"), "- from the page")
        self.assertEqual(self.req("/api/set", {"key": "nope", "pairs": ["status=read"]})[0], 400)

    def test_guards(self):
        body = {"key": "old", "pairs": ["status=read"]}
        self.assertEqual(self.req("/api/set", body, **{"Content-Type": "text/plain"})[0], 403)  # form-style CSRF
        self.assertEqual(self.req("/api/set", body, Origin="http://evil.example")[0], 403)
        self.assertEqual(self.req("/api/data", Host=f"evil.example:{self.port}")[0], 403)  # DNS rebinding

    def test_files(self):
        self.assertEqual(self.req("/file?p=../write-up.md"), (200, "my write-up"))  # linked from a note
        self.assertEqual(self.req("/file?p=../secret.txt")[0], 404)  # exists but not linked


if __name__ == "__main__":
    try: unittest.main(verbosity=2)
    finally: shutil.rmtree(TMP, ignore_errors=True)
