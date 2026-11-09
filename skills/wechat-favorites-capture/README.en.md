# wechat-favorites-capture

English | [中文](./README.md)

Turns the WeChat favorites sitting on your Mac into searchable, citable material in an Obsidian vault. Decrypt the favorites DB, export it, bucket and tier it, pull the article bodies into Markdown, and render a single-file HTML report. **Move, don't process.**

## Why this exists

Your WeChat favorites are the most under-used corner of a personal knowledge base. A few years of "I'll use that someday" articles sit in one encrypted SQLite file — unsearchable and unusable.

Moving them is hard for three reasons:

1. **The database is encrypted.** `favorite.db` is SQLCipher 4. The key exists only in WeChat's process memory, never on disk.
2. **Article pages carry a `poc_token` check.** A plain HTTP request gets a "suspicious environment" verification page. You need a real browser to render it.
3. **You can't scrape all of it.** Hundreds of favorites means hours of scraping, and most of it is stale technical detail that no longer says anything to your writing.

This skill does four things:

1. **Decrypt** — frida hooks WeChat's PBKDF2 derivation; the key unlocks a page-by-page HMAC-verified decrypt
2. **Tier** — topic classification plus a time-based split, so "the forty worth keeping" separates cleanly from "four hundred favorites"
3. **Scrape** — drives a real browser; the HTML→Markdown conversion happens inside the page, and the article body never enters the model's context
4. **Stay reproducible** — the keyword table lives in `data/taxonomy.json`; edit the table to change the buckets, no Python edits

## Architecture

```
  WeChat for Mac (signed in, has favorites)
        │
        │  ① key extraction: frida hook on CCKeyDerivationPBKDF
        │     quit the running WeChat first; needs an ad-hoc re-signed copy
        ▼
  ┌────────────────────────────────────────────────┐
  │  wfc_capture.sh                                 │
  │  ├─ wfc_env.sh        shared .mario-skills/.env │
  │  ├─ decrypt_favorite_db.py   SQLCipher 4 decrypt │
  │  ├─ wfc_classify.py   topics + tiers + URL lists │
  │  ├─ wfc_preflight.sh  browser env check + repair│
  │  └─ wfc_setup.sh      first-run wizard (human) │
  └────────────────────────────────────────────────┘
        │                          │
        │ ② export                │ ③ scrape (chunks ≤6, 20s apart)
        ▼                          ▼
  <dataset>/favorites.json    <dataset>/articles/<category>/{date}-{title}.md
  <dataset>/classified.json   <dataset>/urls/<category>.txt
  <dataset>/report.html
```

**Why chunks of ≤6:** opencli's browser session freezes entirely after a dozen-odd consecutive fetches — it isn't the URL and it isn't tab pile-up (`tab list` shows one tab the whole time). Chunking, a 20-second gap, and retrying only the failures is the combination that actually holds up in practice.

**Why bodies never enter the context:** one article's raw HTML runs from tens to hundreds of KB. The conversion happens in the page and goes straight to disk, so scraping one article and scraping a hundred should cost the same.

## Quickstart

### 1. Dependencies

```bash
npm install -g opencli        # the browser bridge
opencli doctor                 # all green, especially "Extension: connected"
```

Also needed:

- **Chrome** (WeChat article pages need a real browser)
- **The `wechat-article-scraper` skill** (article bodies) — install to `~/.claude/skills/wechat-article-scraper`
- **The `wx-favorites-report` skill** (parsing + HTML report) — the wizard clones it for you

### 2. Configure (once, by a human)

```bash
bash scripts/wfc_setup.sh --detect          # vault, favorites DB, dependency status
bash scripts/wfc_setup.sh --init --dry-run  # preview
bash scripts/wfc_setup.sh --init            # write it
```

The wizard asks where to save the captured content (default `raw`) and installs the decrypt virtualenv (frida + pycryptodome).

If `~/.mario-skills/.env` already defines `VAULT_DIR` — `diary-writer` or `book-enquire-reader` writes one — the wizard leaves it alone.

### 3. Run

```bash
bash scripts/wfc_capture.sh capture --tier T1 --limit 50   # the whole flow, one command
```

`capture` decides on its own whether decryption is needed (it skips `export` when
`favorites.json` already exists), classifies, scrapes, renders the report, and repairs the
browser environment before scraping (daemon, profile, stale tab lease). It ends with one
JSON receipt.

To run a single step:

```bash
bash scripts/wfc_doctor.sh --json                       # preflight
bash scripts/wfc_capture.sh export                     # decrypt → favorites.json
bash scripts/wfc_capture.sh classify                   # classify → classified.json + urls/
bash scripts/wfc_capture.sh scrape                     # bodies → articles/
bash scripts/wfc_capture.sh report                     # HTML report
```

`export` needs the key. The receipt comes back with `error: "key_required"` and the exact command to run — details in `references/decrypt-and-export.md`.

## Configuration

Everything lives in the shared `.mario-skills/.env`:

| Key | Default | Meaning |
|-----|---------|---------|
| `VAULT_DIR` | — | Vault root. **Shared with `diary-writer`, `book-enquire-reader`, `dedao-course-sync`** |
| `WX_FAV_OUT_SUBDIR` | `raw` | Save root, relative to the vault. Absolute paths work too |
| `WX_FAV_SET_SUBDIR` | `WeChat-Favorites` | Dataset subfolder. Empty = store directly in the save root |
| `WX_FAV_TIER` | `T1` | Default tier: `T1` / `T2` / `T3` / `all` |
| `WX_FAV_LIMIT` | `0` | Max articles per run. `0` = no cap |
| `WX_FAV_CHUNK` | `6` | Articles per browser session. Don't raise it |
| `WX_FAV_DELAY` | `20` | Seconds between articles. 15–20 is the safe band |
| `WX_FAV_TAG` | `wechat-favorites` | Tag written into frontmatter |
| `WX_FAV_SESSION` | `wxscrape` | opencli browser session name. The preflight and the scraper share it |
| `WX_FAV_STATE_DIR` | `~/.local/share/wechat-favorites-capture` | Decrypt workspace, key log, venv. Outside the vault and the skill |
| `WX_FAV_DB` | auto | Path to the WeChat favorites database |
| `WX_FAV_VIZ_SKILL` | auto | Where `wx-favorites-report` lives |
| `WX_FAV_SCRAPER_SKILL` | auto | Where `wechat-article-scraper` lives |
| `OPENCLI_BIN` | `opencli` | Browser bridge. **Shared with `dedao-course-sync`** |

Resolution order: `process.env` → `<project>/.mario-skills/.env` → `~/.mario-skills/.env` → built-in defaults. Each key resolves on its own; unknown keys are ignored.

Inspect where each value came from: `bash scripts/wfc_capture.sh config-info` (add `--json` for machine output).

Full template: [`examples/env.shared.example`](./examples/env.shared.example).

## Commands

```bash
# preflight (agents may run this)
bash scripts/wfc_doctor.sh --json

# pipeline
bash scripts/wfc_capture.sh export [--keylog P | --key HEX]
bash scripts/wfc_capture.sh classify [--tier T1|T2|T3|all] [--limit N]
bash scripts/wfc_capture.sh scrape [--category C] [--tier T] [--limit N] [--dry-run]
bash scripts/wfc_capture.sh report
bash scripts/wfc_capture.sh all [scrape options...]
bash scripts/wfc_capture.sh capture [--tier T] [--limit N] [--category C] [--dry-run] [--no-report]
                                      # the whole flow in one command; skips export if already done

# browser-environment self-check and self-repair (capture calls it automatically)
bash scripts/wfc_preflight.sh --session wxscrape

# rewrite the dataset README from what is on disk (counts + gap accounting)
python3 scripts/wfc_readme.py [--check]

# configuration (human only — never from an LLM call)
bash scripts/wfc_setup.sh --init [--dry-run]
bash scripts/wfc_setup.sh --detect
```

### Output contract

**stdout carries one JSON receipt; everything human-facing goes to stderr.** Callers can `json.loads(stdout)` directly.

`all` returns a *summary* of the four steps (export / classify / scrape / report, each with its own block: favorites total, category count, tier distribution, articles fetched and failed) rather than repeating only the last step.

| Exit code | Meaning |
|-----------|---------|
| 0 | Success |
| 1 | The step failed — read `error` in the receipt |
| 2 | Config missing, vault absent, bad argument |

`--init` and `--detect` are human-run commands. Never execute them from an LLM call.

**Where the tier filter lives.** `classify` writes every tier's URLs into `urls/<category>.txt` and records each URL's tier in `urls/_index.json`; `scrape --tier T2` then picks the T2 entries out of that index one by one. Classify once, switch tiers freely. `scrape` defaults to the configured `WX_FAV_TIER` (`T1`).

**`--limit N` is a total budget**, not N per category. It is spent across categories largest-first; `--limit 0` (the default) means no cap. Use `--category` to pin one bucket.

## Why scripts rather than an agent driving the steps

The first version let an agent drive the pipeline step by step. One run cost **over 100k
tokens** — not because the task is complex, but because the agent was doing three things
scripts should do:

1. **Reading source code** (`sed -n 1,80p scrape.py`, `grep canon_url`) to learn the CLI
2. **Running `opencli --help`** to learn the browser bridge's commands
3. **Re-diagnosing the same mechanical failure** — daemon down, no profile selected, a
   stale tab lease from the previous run. All three look like "browser failed to open",
   and each one costs a fresh round of reasoning.

All of that now lives in `scripts/`: `wfc_preflight.sh` checks and repairs the browser
environment, `capture` chains the four steps into one command, and the agent reads one
JSON receipt. **A failure goes from "something to reason about" to "something to re-run".**

## Known limits

**Decryption is macOS-only.** Key extraction attaches to the WeChat process via frida, and WeChat ships no desktop Linux or Windows build.

**Key extraction is not fully automatic.** You have to quit the running WeChat, prepare a re-signed copy, and sign in within the 300-second window. A script cannot log in for you.

**The key changes when WeChat upgrades.** The symptom is an HMAC mismatch during decryption; re-run the extraction.

**Some favorites can never be scraped.** The original was deleted, taken down for policy reasons, or the author restricted access — retrying changes nothing. The metadata (title, source, when you saved it) still survives; only the body is gone.

**The `IMG` tier is mostly dead.** Most `image_detail` entries in a favorites folder have been deleted or restricted; the skill doesn't spend scraping budget on them.

**The keyword table is a starting point, not the answer.** `data/taxonomy.json` was tuned against one corpus — technical plus self-media. A different favorites folder needs a different table, or a taxonomy of your own.

**Images are not downloaded.** Article images keep their `mmbiz.qpic.cn` CDN URLs. If your vault runs `obsidian-local-images-plus`, exclude the capture directory or the plugin will pull every image into `assets/` and rewrite the links — see `references/scraping.md`.

**Favorites are sensitive material.** Titles, sources, and summaries record one person's browsing habits. Keep it local; don't publish it.

## License

MIT — see [LICENSE](./LICENSE).
