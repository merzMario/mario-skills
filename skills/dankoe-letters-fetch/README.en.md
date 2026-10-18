# dankoe-letters-fetch

中文 | [English](./README.md)

Incrementally fetch [Dan Koe's newsletter](https://letters.thedankoe.com) into your Obsidian vault under `raw/DanKoe/原文/`. **Fetch only; no editorializing.**

## Why this exists

Dan Koe publishes a free newsletter weekly that is worth archiving as source material. But Substack's archive API has four non-obvious constraints, and violating any one of them **silently under-fetches or fetches the wrong thing** — none of the symptoms look like an error:

1. `limit` caps at 23. Values of 24/30 are **silently clamped back** to 23 (no error); only 100 raises `Invalid value`. You must page with an offset step of exactly 23.
2. `body_html` in the archive **listing** is always `null` — the body lives only on the single-post endpoint `/api/v1/posts/<slug>`.
3. A paywall cannot be detected by scanning body keywords — a paywalled truncation may contain **no explicit wording at all**, just a word cut mid-syllable.
4. Substack appends disambiguation suffixes to republished posts (`-ef8`). Those are **different articles**, so dedup must match slugs exactly.

Constraints 1 and 3 are the dangerous ones: neither errors, the result is just wrong. Encoding this as prompt prose means re-discovering it every time, so it lives here as **code**.

## Architecture

```
  letters.thedankoe.com
          │
          │ ① enumerate (pure curl, zero browser)
          │   GET /api/v1/archive?sort=new&limit=23&offset=N
          │   exactly 23 per page — larger limits get clamped back
          │   each entry carries `audience`: everyone=free / only_paid=paywalled
          ▼
      ┌────────────────────────────┐
      │  dankoe_fetch.sh           │  bash entry: resolves .mario-skills/.env
      │  └─ dankoe_fetch.py        │  Python core: enumerate / dedup / fetch / clean
      └────────────────────────────┘
          │
          │ ② dedup: slugs from filenames in 原文/, matched **exactly**
          │ ③ body: opencli browser extract --selector article
          │    fallback: single-post body_html (after two browser failures)
          ▼
  $VAULT_DIR/raw/DanKoe/原文/20260919-the-one-human-business-原文.md
  $VAULT_DIR/raw/DanKoe/翻译/20260919-the-one-human-business-翻译.md   ← separate flow
```

**Why dedup must match slugs exactly**: prefix matching mistakes an `-ef8` republished version for one you already have, and those are different articles.

## Quickstart

### 1. Dependencies

```bash
# list only needs curl
curl --version

# fetch needs the browser bridge
npm install -g opencli
opencli doctor              # must be all green, especially "Extension: connected"
```

Substack is public — **no login required**. But the body renders client-side, so fetching still needs a browser plus the OpenCLI extension.

### 2. Configure (once, by a human)

```bash
bash scripts/dankoe_fetch.sh --detect
bash scripts/dankoe_fetch.sh --init
```

If `~/.mario-skills/.env` already has `VAULT_DIR` (written by another mario skill), this skill works as-is.

### 3. Fetch

```bash
bash scripts/dankoe_fetch.sh list  --count 10    # what's new
bash scripts/dankoe_fetch.sh fetch --count 10    # fetch it
```

## Configuration

Everything resolves through the shared `.mario-skills/.env`:

| Key | Default | Meaning |
|-----|---------|---------|
| `VAULT_DIR` | — | Vault root. **Shared with `diary-writer`, `book-enquire-reader`, `dedao-course-sync`** |
| `DANKOE_OUT_SUBDIR` | `raw/DanKoe` | Output root; articles land in its `原文/` subdirectory |
| `DANKOE_SESSION` | `dankoe-letters` | opencli session name. Don't share one across processes |
| `DANKOE_COUNT` | `10` | Default batch size |
| `DANKOE_STATE_DIR` | `~/.local/share/dankoe-letters-fetch` | Failure log |
| `OPENCLI_BIN` | `opencli` | The browser bridge |

Resolution order: `process.env` → `<project>/.mario-skills/.env` → `~/.mario-skills/.env` → built-in defaults.

Inspect: `bash scripts/dankoe_fetch.sh --config-info` (`--json` for machine use).

> ⚠️ Historically this skill pointed at `00-Raw/DanKoe/原文/`. When you reorganized the vault on 2026-10-12 (`00-Raw/` → `raw/`), the actual output moved to `raw/` but the skill did not — which **silently broke dedup entirely**, re-fetching every article on every run. It now points at `raw/DanKoe/`.

## Commands

```bash
bash scripts/dankoe_fetch.sh list  [--count 10]
bash scripts/dankoe_fetch.sh fetch [--count 10] [--dry-run]

bash scripts/dankoe_fetch.sh --init [--project] [--dry-run]
bash scripts/dankoe_fetch.sh --detect
bash scripts/dankoe_fetch.sh --config-info [--json]
```

`--init` and `--detect` are for a human at a terminal — never call them from an LLM.

### Output contract

**stdout carries only JSON receipts; everything human-readable goes to stderr.**

| Exit code | Meaning |
|-----------|---------|
| 0 | Success (including "nothing new") |
| 1 | **Any article failed** |
| 2 | Missing config, missing vault, bad arguments, opencli absent (`fetch` only) |

The failure log is written to `$DANKOE_STATE_DIR/dankoe-fetch-errors.json` and deleted after a fully successful run.

## Output format

`原文/YYYYMMDD-{slug}-原文.md`:

```markdown
# {English Title}

### {Subtitle}

**Source**: https://letters.thedankoe.com/p/{slug}
**Published**: {YYYY-MM-DD}
**Author**: Dan Koe

---

{body}
```

Bold key/value lines, **not YAML frontmatter** — that is the established convention in `raw/DanKoe/` (the 95 files under `翻译/` use it too), and switching would break downstream parsers.

Dates always come from the archive's ISO field. **Never use the displayed date** — `Sep 20, 2026` is rendered in local time and can be a day off.

## Known limitations

**Render waiting is mandatory.** Substack renders progressively; extracting too early yields either `selector_not_found` (easy to spot) or a **truncated body** that cuts mid-word and looks like a paywall but is a false positive. Hence open → wait for selector → settle 2.5s → extract, and re-extract if the tail signature is missing.

**Completeness is judged by tail signature, not length.** A body must be ≥ 1000 characters **and** end with `Likes` / `Restacks` / `– Dan` before it is written. Length alone misses the "fetched most of it" case.

**The archive can contain deleted posts.** Measured 2026-10-18: the vault holds 95 articles, the archive lists 91, and 5 of those return `Post not found` on both the archive and the single-post endpoint (deleted upstream). So **`exhausted: true` means "the archive is caught up", not "vault and archive agree"**.

**Images are not downloaded.** CDN URLs are preserved.

**Translation is a separate flow.** The `翻译/` directory is maintained by a different process; this skill does not touch it.

## License

MIT — see [LICENSE](./LICENSE).
