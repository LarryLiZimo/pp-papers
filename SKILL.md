---
name: pp
description: Keep the user's paper library with the `pp` CLI (plain text, one Markdown file per paper). Use whenever the user mentions reading, finishing or wanting to read a paper, shares an arXiv/DOI/paper link to save, asks what they have read or noted on a topic or how papers relate (lineage), or needs BibTeX.
---

# Paper library (`pp`)

Every paper is `$PP_DIR/<key>.md` (default `~/papers`): YAML front matter (metadata, links) plus Markdown (`## Notes`, `## Abstract`). `pp -h` lists everything. If `pp` is not on PATH and this skill came with the Claude Code plugin, run `"${CLAUDE_PLUGIN_ROOT}/pp"` in its place.

| Command | Does |
|---|---|
| `pp add <arxiv-id\|doi\|url\|title>... [-s] [-t a,b]` | fetch metadata, create files, print keys (title and venue on stderr); `-s` stars them |
| `pp ls [-s] [-t tag]` | TSV: key, year, star (`*` or empty), tags, title (key order; pipe to `sort` / `grep`); `-s`: starred only |
| `pp get <field> [key...]` | read `path`, `bib`, `url`, `notes`, `abstract`, `title`, `builds_on`, any field; no key = all papers |
| `pp set <key> field=value...` | write fields (below); `-` as a value reads stdin |
| `pp mv <key> <new-key>` | rename; references in other papers follow |
| `pp link` | fetch citations between library papers; fill in published venue and year |
| `pp graph` | serve the editable lineage page (blocks until Ctrl+C) |

`set` forms: `star=true` / `star=false`, `tags+=a,b`, `tags-=a`, `builds_on+=<key>,<key>`, `builds_on-=<key>`, `year=2017 venue=CVPR`, `notes+="a line"` (appends; a bare line becomes `- line`), `notes=-` (replace from stdin).

## Rules

- **Never write title, authors, year or venue from memory.** Find the arXiv id or DOI (search the web if needed), let `pp add` fetch the metadata, and check that the title it prints is the paper the user meant.
- **Notes belong to the user.** Never write, summarize into or tidy `## Notes` on your own, including after "I read X". Write there only when the user asks you to, in their words. Reading notes to answer a question is fine.
- **`builds_on` says one paper's idea comes from another**, both in the library. Ground it in the abstracts (`pp get abstract <key>`); propose links and add them once the user agrees, unless they told you the relation.
- **`cites` is machine-managed** by `pp link`. Don't edit it.
- **Keys** (`qi2017pointnet`) are permanent IDs; commands accept any unique prefix or substring of a key or title (`vggt`, `mast3r`). Auto keys use the title's first word, so when a paper is known by another name (VGGSfM, MASt3R), rename it right after adding: `pp mv wang2024visual wang2024vggsfm`.
- Change files through `pp set`, not by hand, so the format stays parseable.

## "I read / finished X"

1. `pp add <id> [-t tags]`, unless it is already in the library. Star it only if the user asks.
2. `pp ls`, compare with the library, and propose `builds_on` links in both directions: `pp set <key> builds_on+=<older>` / `pp set <newer> builds_on+=<key>`.
3. `pp link`. If it prints a `pp mv` hint (Semantic Scholar corrected the year in a key), apply it. An open lineage page picks up every change by itself.

## Other requests

| User wants | Do |
|---|---|
| Save for later | `pp add <id>` |
| Star or unstar X | `pp set <key> star=true` / `star=false` |
| "Note that ..." about a paper | `pp set <key> notes+="..."` in their words. The user may be editing the same notes in the page, so `pp get notes <key>` first before replacing them with `notes=-`. |
| What have I read on X / where did I note X | `grep -ril "X" "${PP_DIR:-$HOME/papers}"`, then `pp get notes <keys>`; `pp ls -s` (starred), `pp ls -t <tag>` |
| See or edit the lineage | Tell the user to run `pp graph`. It blocks, so don't run it in the foreground yourself; if asked, run it in the background. The page stars papers, edits details and notes, adds, deletes and links papers (drag a card's dot onto another card: the older paper becomes the source, and Flip reverses it), and lets cards be dragged around; Arrange lays them out again. |
| BibTeX | `pp get bib <key>...`, or `pp get bib > refs.bib` for everything |

## When metadata is off

Without an API key Semantic Scholar is often rate-limited (HTTP 429). `add` then keeps the arXiv year with venue `arXiv`, and a later `pp link` fills in the published venue and year. Fix anything else with `pp set <key> year=2017 venue=CVPR`. Setting `S2_API_KEY` makes lookups reliable.
