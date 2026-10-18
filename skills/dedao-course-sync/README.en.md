# dedao-course-sync

中文 | [English](./README.md)

Incremental sync of two paid 得到 (Dedao) columns — 得到精选 and 得到头条 — into an Obsidian vault under `raw/Courses-GetIt/`. **Fetch only; no editorializing.**

## Why this exists

Two of Dedao's columns publish daily. Manual bookmarking always breaks: gaps, duplicates, inconsistent formatting.

This skill does three things:

1. **Incremental** — dedupes on Dedao's own article ID (`article_id`), never re-fetching what it already has
2. **Verifiable** — every article carries frontmatter (`article_id` / `source` / `published`) that traces back to Dedao
3. **Clean** — body text comes from `.article-body` only, with page chrome stripped; a renamed title does not defeat dedup

## Architecture

```
  Chrome (already logged into 得到) + OpenCLI extension
                │
                │  ① list: in-page fetch against the JSON endpoint
                │     POST /pc/bauhinia/pc/class/purchase/article_list
                │     reverse=true newest-first · count≤50 · max_id cursor paging
                ▼
      ┌───────────────────────────┐
      │  dedao_sync.sh            │  bash entry: resolves .mario-skills/.env
      │  └─ dedao_sync.py         │  Python core: paging / dedup / fetch / clean
      └───────────────────────────┘
                │
                │  ② dedup: scan frontmatter article_id (never filenames)
                │  ③ body: opencli browser extract --selector .article-body
                ▼
  $VAULT_DIR/raw/Courses-GetIt/得到精选/2026-10-17-为什么越追求平等越不平等.md
  $VAULT_DIR/raw/Courses-GetIt/得到头条/…
```

**Why dedup keys on `article_id` rather than the filename**: titles get edited and the slug-cleaning rules have changed over time (see section 4 of `SKILL.md`). Matching on filenames re-fetches every article whose title was ever touched.

## Quickstart

### 1. Dependencies

```bash
npm install -g opencli          # the browser bridge
opencli doctor                   # must be all green, especially "Extension: connected"
```

Chrome must be **logged into 得到**, with the [OpenCLI extension](https://chromewebstore.google.com/detail/opencli/ildkmabpimmkaediidaifkhjpohdnifk) installed. The script holds no credentials — you sign in, in the browser.

### 2. Configure (once, by a human)

```bash
bash scripts/dedao_sync.sh --detect    # local vaults and opencli status
bash scripts/dedao_sync.sh --init      # writes ~/.mario-skills/.env
```

If `~/.mario-skills/.env` already has `VAULT_DIR` (written by `diary-writer` or `book-enquire-reader`), this skill works as-is with no extra configuration.

### 3. Fetch

```bash
bash scripts/dedao_sync.sh fetch --course all --count 20
```

Roughly 4–6 seconds per article; 20 articles across both columns is about 4 minutes.

## Configuration

Everything resolves through the shared `.mario-skills/.env` — the marketplace-wide convention:

| Key | Default | Meaning |
|-----|---------|---------|
| `VAULT_DIR` | — | Vault root. **Shared with `diary-writer` and `book-enquire-reader`** |
| `DEDAO_OUT_SUBDIR` | `raw/Courses-GetIt` | Output directory, relative to the vault |
| `DEDAO_SESSION` | `dedao-sync` | opencli browser session name. Concurrent runs fight over the same tab; never share one |
| `DEDAO_COUNT` | `20` | Default batch size, used when `--count` is omitted |
| `DEDAO_STATE_DIR` | `~/.local/share/dedao-course-sync` | Failure log. Neither in the vault nor in the skill directory |
| `OPENCLI_BIN` | `opencli` | The browser-bridge executable |

Resolution order: `process.env` → `<project>/.mario-skills/.env` → `~/.mario-skills/.env` → built-in defaults. Resolved per key; unknown keys ignored.

Inspect: `bash scripts/dedao_sync.sh --config-info` (`--json` for machine use).

**Course IDs, slug-cleaning tables and body anchors are deliberately not configurable.** They travel as a set: swapping only the course ID leaves the slug rules and `body_anchor` mismatched, producing files that are wrong but look fine. Adding a column means changing all three.

## Commands

```bash
# fetch
bash scripts/dedao_sync.sh fetch --course all [--count 20] [--dry-run]

# just show what is new
bash scripts/dedao_sync.sh list --course all

# configuration
bash scripts/dedao_sync.sh --init [--project] [--dry-run]
bash scripts/dedao_sync.sh --detect
bash scripts/dedao_sync.sh --config-info [--json]
```

`--init` and `--detect` are for a human at a terminal — never call them from an LLM.

### Output contract

**stdout carries only JSON receipts; everything human-readable goes to stderr.** Callers can `json.loads(stdout)` without parsing prose.

| Exit code | Meaning |
|-----------|---------|
| 0 | Success (including "nothing new") |
| 1 | **Any article failed** — partial failure is never swallowed, so cron and launchd notice |
| 2 | Missing config, missing vault, bad arguments, opencli not on PATH |

The failure log is written to `$DEDAO_STATE_DIR/dedao-sync-errors.json`. A fully successful run deletes the stale one — leaving it around only misleads.

## Known limitations

**Requires a logged-in Chrome.** Dedao is paid content and the script has no credentials. This is a hard constraint with no workaround.

**A Dedao redesign breaks it.** The script hardcodes the `.article-body` selector and the preamble anchors (`你好` / `这里是《` / `各位`). After a redesign the symptoms are "waited 45s, still unqualified" or "only N characters left after cleaning"; fix the selector or the anchor. The full triage procedure is documented in `raw/Courses-GetIt/README.md` inside the vault.

**Two columns only.** Dedao 精选 and Dedao 头条. The other four course directories alongside them are completed courses fetched once by an older pipeline — this skill does not touch them.

**`--dry-run` still needs the browser.** The pending list comes from that JSON endpoint; without calling it there is no list to show. What it guarantees is "writes no files".

**Images are out of scope.** Remote links are preserved; Obsidian's `obsidian-local-images-plus` plugin downloads and rewrites them.

**Run serially, never concurrently.** Two processes on the same `DEDAO_SESSION` swap each other's tab, and the body probe reads the previous article.

## License

MIT — see [LICENSE](./LICENSE).
