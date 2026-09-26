---
name: pp
description: Keep the user's paper library with the `pp` CLI (plain text, one Markdown file per paper). Use whenever the user mentions reading, finishing or wanting to read a paper, shares an arXiv/DOI/paper link to save, wants notes on a paper, asks what they have read on a topic or how papers relate (lineage), or needs BibTeX.
---

# Paper library (`pp`)

Every paper is `$PP_DIR/<key>.md` (default `~/papers`): YAML front matter (metadata, links) plus Markdown sections (`## TL;DR`, `## Notes`, `## Abstract`). `pp -h` lists everything.

| Command | Does |
|---|---|
| `pp add <arxiv-id\|doi\|url\|title>... [-s queue\|reading\|read] [-t a,b]` | fetch metadata, create files, print keys (title and venue on stderr) |
| `pp ls [-s status] [-t tag]` | TSV: key, year, status, tags, title (key order; pipe to `sort` / `grep`) |
| `pp get <field> [key...]` | read `path`, `bib`, `url`, `tldr`, `notes`, `abstract`, `title`, `builds_on`, any field; no key = all papers |
| `pp set <key> field=value...` | write fields and sections (below); `-` as a value reads stdin |
| `pp mv <key> <new-key>` | rename; references in other papers follow |
| `pp link` | fetch citations between library papers; fill in published venue and year |
| `pp graph` | serve the editable lineage page (blocks until Ctrl+C) |

`set` forms: `status=read` (stamps the read date), `tags+=a,b`, `tags-=a`, `tldr="one sentence"`, `notes+="one bullet"` (appends; a bare line becomes `- line`), `notes=-` (replace from stdin), `builds_on.<key>="why"` (an empty value removes the link), `year=2017 venue=CVPR`.

## Rules

- **Never write title, authors, year or venue from memory.** Find the arXiv id or DOI (search the web if needed), let `pp add` fetch the metadata, and check that the title it prints is the paper the user meant.
- **Notes are the user's voice.** Record what *they* said or thought, in their language, as terse bullets via `notes+=`. No generic summaries; if they gave no takeaway, ask. You may write `tldr`: one sentence on what the paper claims, grounded in its abstract (`pp get abstract <key>`).
- **`builds_on` is a claim about ideas**: only between papers in the library, one short reason each ("adds X to Y", "replaces A with B"), grounded in the abstracts. Propose links and let the user confirm, unless they told you the relation.
- **`cites` is machine-managed** by `pp link`. Don't edit it.
- **Keys** (`qi2017pointnet`) are permanent IDs; commands accept any unique prefix or substring of a key or title (`vggt`, `mast3r`). Auto keys use the title's first word, so when a paper is known by another name (VGGSfM, MASt3R), rename it right after adding: `pp mv wang2024visual wang2024vggsfm`.
- Change files through `pp set`, not by hand, so the format stays parseable. The user may be editing the same paper in the lineage page; re-read with `pp get` before replacing a whole section.

## "I read / finished X"

1. `pp add <id> -s read [-t tags]`. If it says "already in library": `pp set <key> status=read`.
2. `pp set <key> tldr="..."`, grounded in the abstract.
3. Record the user's takeaways: `pp set <key> notes+="..."` per bullet, or `notes=-` with a heredoc. If they keep a longer write-up elsewhere, add a bullet linking it (`[write-up](../path/to/file.md)`, relative to the library folder, or an absolute path).
4. `pp ls`, compare with the library (`pp get tldr` helps), and propose `builds_on` links in both directions: `pp set <key> builds_on.<older>="why"` / `pp set <newer> builds_on.<key>="why"`.
5. `pp link`. If it prints a `pp mv` hint (Semantic Scholar corrected the year in a key), apply it. An open lineage page picks up every change by itself.

## Other requests

| User wants | Do |
|---|---|
| Save for later | `pp add <id> -s queue` |
| Started reading | `pp set <key> status=reading` |
| What have I read on X / where did I note X | `grep -ril "X" "${PP_DIR:-$HOME/papers}"`, then `pp get notes <keys>`; `pp ls -s read`, `pp ls -t <tag>` |
| See or edit the lineage | Tell the user to run `pp graph`. It blocks, so don't run it in the foreground yourself; if asked, run it in the background. The page edits status, details, TL;DR and notes, adds, deletes and links papers (drag a card's dot onto another card), and lets cards be dragged around. |
| BibTeX | `pp get bib <key>...`, or `pp get bib > refs.bib` for everything |

## When metadata is off

Without an API key Semantic Scholar is often rate-limited (HTTP 429). `add` then keeps the arXiv year with venue `arXiv`, and a later `pp link` fills in the published venue and year. Fix anything else with `pp set <key> year=2017 venue=CVPR`. Setting `S2_API_KEY` makes lookups reliable.
