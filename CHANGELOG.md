# Changelog

All notable changes to this marketplace. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [semver](https://semver.org/spec/v2.0.0.html).

The version here is the single source of truth — it lives in `metadata.version` in
`.claude-plugin/marketplace.json` and is what users receive on marketplace update.

## 0.9.1 - 2026-11-09

### Fixes
- `wechat-favorites-capture`: **the retry pass never ran, and failures were never counted.** The retry built its URL list into `rretry` but read it back as `${rtretry[@]}` — one extra letter, so the array was always empty, `run_chunk` returned immediately, and the article was never re-fetched. The receipt still counted the attempt (`retried: N`) and reported `failed: 0`, so a run where an article could not be fetched looked exactly like a clean run. Both were wrong in the same direction: the receipt said "nothing failed" while the article was missing from disk. The misspelling was invisible because a shell array that was never assigned expands to nothing under `set -u` instead of erroring. Found by running `bash -x` over a failing run and reading the trace — the retry's `run_chunk` was called with no URL at all
- `wechat-favorites-capture`: the receipt now reports `failed` and lists the URLs in `failed_items` after the retry, instead of always claiming zero failures

### Features
- `wechat-favorites-capture`: **failures are persisted to `urls/_failed.json`** and survive across runs; entries that later succeed are dropped. The file separates "tried it and the original is gone" from "not reached yet" — without it a gap report reads as if two hundred never-attempted old articles had failed the same way as five deleted ones
- `wechat-favorites-capture`: **`scripts/wfc_readme.py` rewrites the dataset README from what is on disk** — the per-category article table (counts, characters, CDN images) and a gap accounting section that splits each tier into landed / unreachable / not-yet-attempted. The gap section is written at the end of the file on purpose: the articles section above is replaced wholesale, so anything kept inside it is silently wiped on the next run. `--check` reports staleness without writing

## 0.9.0 - 2026-11-08

### Features
- `wechat-favorites-capture`: **`capture` puts the whole fixed flow behind one command** — check whether decryption is needed, classify, scrape, report, and print one JSON receipt. The point is token cost: letting an agent drive the four steps one at a time cost over 100k tokens per run, not because the task is complex but because the agent was reading `scrape.py` source to learn the CLI, running `opencli --help`, and re-diagnosing the same mechanical browser failure on every run. A failure goes from "something to reason about" to "something to re-run"
- `wechat-favorites-capture`: **`wfc_preflight.sh` checks and repairs the browser bridge before scraping** — starts the opencli daemon if it is down, selects a Chrome profile when the extension is connected but no profile is selected, releases a stale session lease left by a dead run, and verifies the browser can actually render a page. All three failures present as "browser failed to open" and none of them needs a human to reason about it
- `wechat-favorites-capture`: brings the WeChat Mac favorites folder into the vault. Four steps — decrypt the SQLCipher `favorite.db`, export and classify every favorite, scrape the article bodies into Markdown, render a single-file HTML report. Output defaults to the vault's `raw/`, and the first-run wizard asks where to put it before anything is written
- `wechat-favorites-capture`: **ships the SQLCipher 4 decryptor.** The upstream `wx-favorites-report` repository has no decryption code — its `SKILL.md` pointed at an author's local script that was never published. `decrypt_favorite_db.py` implements the cipher from the sqlcipher 4.6.1 source spec (PBKDF2-HMAC-SHA512, 256000 rounds, per-page HMAC-SHA512 over `ciphertext || iv || pgno`) and verifies every page's HMAC before writing; a page that fails the check is never emitted, so a wrong key produces an error rather than a half-decrypted database
- `wechat-favorites-capture`: the classifier is data, not code. `data/taxonomy.json` holds the strong/weak keyword tables, the source-inheritance window, the hand-decision overrides, the tier rules, and the editorial-column heuristic — edit the JSON to change the buckets and re-run, with no Python edits. Verified against a 481-item favorites corpus: identical per-item buckets, identical category distribution, identical column counts, zero divergence
- `wechat-favorites-capture`: **the dependency guarantee lives in the setup wizard.** `--init` creates the decrypt virtualenv (frida + pycryptodome), clones `wx-favorites-report` if it is missing, and reports the two it cannot install — the `wechat-article-scraper` skill and `opencli`. `wfc_doctor.sh` re-checks all of it as JSON so an agent sees a precise missing list before touching anything. The wizard leaves `VAULT_DIR` and `OPENCLI_BIN` alone when the shared `.env` already defines them, so it cannot clobber a sibling skill's settings
- `wechat-favorites-capture`: the scraping failure mode is encoded rather than described. Chunks are capped at 6 articles per browser session with a 20-second gap, because opencli's browser session freezes entirely after a dozen consecutive fetches — the symptom is "browser failed to open", not a rate limit, and the fix is chunking plus retrying only the failures read out of `.index.json`, never the whole batch
- `wechat-favorites-capture`: config moved onto the shared `.mario-skills/.env` with `--config-info` source reporting. Keys: `WX_FAV_OUT_SUBDIR`, `WX_FAV_SET_SUBDIR`, `WX_FAV_TIER`, `WX_FAV_LIMIT`, `WX_FAV_CHUNK`, `WX_FAV_DELAY`, `WX_FAV_TAG`, `WX_FAV_STATE_DIR`, `WX_FAV_DB`, `WX_FAV_VIZ_SKILL`, `WX_FAV_SCRAPER_SKILL`. `VAULT_DIR` and `OPENCLI_BIN` are the keys it shares with the other skills

### Fixes
- `wechat-favorites-capture`: **an explicitly empty config value was treated as "not set".** `env_get` returned 1 both for a missing key and for a key written as `KEY=`, and the process-environment snapshot used `${VAR-}`, which cannot tell an empty value from an absent one. `WX_FAV_SET_SUBDIR=` — the wizard's own way of saying "store the dataset directly in the save root" — was silently ignored and the built-in default won. `env_get` now reports presence separately from emptiness, and the snapshot uses a marker for "unset"
- `wechat-favorites-capture`: **non-WeChat links no longer enter the scrape list.** A favorites folder holds Douyin video pages, Toutiao, 51CTO and assorted news sites alongside actual WeChat articles; the body scraper only handles `mp.weixin.qq.com`, so those links used to spin through three retries each — roughly two wasted minutes apiece — and then report a failure that looked like "the article is gone". They are now diverted into `urls/_skipped.json` and counted in the receipt as `skipped_not_wechat`
- `wechat-favorites-capture`: `scrape` now retries each failure **once**. The browser session freezing is a per-chunk problem, not a per-article one, so the failures of a chunk often succeed on a fresh session; retrying only the missing ones keeps the "don't re-fetch what succeeded" rule intact. Still one attempt only — a deleted or private original never comes back, and the retry would just burn the budget
- `wechat-favorites-capture`: `WX_FAV_SESSION` is now a real config key, so the browser-environment preflight and the body scraper always use the same session name
- `wechat-favorites-capture`: the URL lists were written in first-seen order (≈ chronological), which is also the order `scrape --limit` spends its budget in — so "grab 30" went to the oldest categories first. The manifest is now ordered by count, descending
- `wechat-favorites-capture`: **the tier filter compared one tier for the whole list instead of per item.** `scrape --tier T2` after a `classify --tier T1` run returned zero articles and read like "there is nothing to capture". `classify` now writes every tier into the URL lists and records each URL's tier in `urls/_index.json`; `scrape --tier` picks the matching entries out of that index one by one. Classify once, switch tiers freely
- `wechat-favorites-capture`: **the tier filter was also silently returning one article per category.** A quoted `$(...)` inside an array assignment is *one* word — the multi-line output landed in a single element, so every category contributed one bogus "URL" and the filter matched nothing. The filtered list now goes through a temp file and is read back into the array line by line
- `wechat-favorites-capture`: `canon()` turned an empty link into the literal `https://`, and five of those placeholders survived into `urls/*.txt` where the scraper treated them as real articles. Empty and malformed links now return `""`
- `wechat-favorites-capture`: `classify` left stale `.txt` files in `urls/` from an earlier run; a category that no longer existed would still be scraped. The directory is cleared before writing
- `wechat-favorites-capture`: `doctor` marked the decrypt virtualenv as required, which made it read as a blocker even for `classify`-only work. It only gates `export`, so it is now optional and the detail says so
- `wechat-favorites-capture`: the scraper inherited the caller's stdin while running inside a loop over a heredoc, so it could swallow the remaining categories. It now runs with `</dev/null`
- `wechat-favorites-capture`: the setup wizard's `ensure_venv` used `a || b && c`, which parses as `(a || b) && c` — the pip fallback ran even when `uv` had already succeeded. The two paths are now separate branches
- `wechat-favorites-capture`: the wizard aborted under `set -u` when the favorites database could not be auto-detected, because `w_db` was read before it was initialised
- `wechat-favorites-capture`: **`scrape --limit` was a per-category cap, so asking for 30 articles across 14 categories meant up to 420.** It is now a total budget, spent across categories in the order the classifier ranked them. `--category` still pins one bucket
- `wechat-favorites-capture`: `all` now returns a summary receipt covering all four steps — favorites total, category count, tier distribution, articles fetched and failed, report path — instead of repeating only the last step's receipt
- `wechat-favorites-capture`: the wizard's config merge used `env_get ... || grep ... && mv ...` for the two shared keys. `||` and `&&` have equal precedence and associate left to right, so when the key was already present the wizard still tried to move a temp file that was never created. The two branches are now explicit `if` blocks

### Notes
- Decryption is macOS-only: the key is extracted by attaching to the running WeChat process with frida, and WeChat ships no desktop Linux or Windows build. `references/decrypt-and-export.md` documents the ad-hoc re-signing step (which must use `ditto`, not `cp -R`, or the signature comes out incomplete and WeChat refuses to launch) and the key-cleanup steps
- Some favorites can never be scraped: the original was deleted, taken down for policy reasons, or the author restricted access. The skill reports those as "原文已不可见" rather than as retryable failures, and does not attempt to work around any access control
- The favorites corpus records one person's browsing habits. It stays local; `favorite_plain.db` should be gitignored by the vault, and the key log and the re-signed WeChat copy should be deleted after use

## 0.8.0 - 2026-10-18

### Features
- `wewrite`: WeChat Official Account pipeline as a single skill — topic → brief and claims → draft → editorial pass, with images, formatting, and draft-box push as separate opt-in steps. Ported from [imraywang/wewrite](https://github.com/imraywang/wewrite) 4.2.1 (MIT), which shipped as a main skill plus nine sibling skills; collapsed into one directory because mario-skills requires every skill to be self-contained
- `wewrite`: **the output root is now split from the state root.** `paths.out_dir()` reads `WEWRITE_OUT_DIR`, defaulting to `$VAULT_DIR/output/WeWrite`. Every run artifact — draft, brief, claims, sources, review report, images, preview — lands in the vault, while `config.yaml`, `style.yaml`, `history.yaml`, `playbook.md`, and the learning corpora stay on the machine. Upstream had one `WEWRITE_HOME` for both, which would have put WeChat credentials into a git repo that is also iCloud-synced
- `wewrite`: run artifact paths are stored relative to the output root rather than as absolute paths, so moving `runs/` (or changing `WEWRITE_OUT_DIR`) keeps existing `state.yaml` resolvable
- `wewrite`: config moved onto the shared `.mario-skills/.env`, replacing the per-skill `config.yaml`. Four-layer chain — process env → `<cwd>/.mario-skills/.env` → `~/.mario-skills/.env` → built-in defaults — resolved per key, so setting one key never resets another. The upstream `config.yaml` is retained as the lowest fallback layer, so old installs keep working
- `wewrite`: `.env` values are parsed, never sourced. A credentials file that gets `source`d is a code-execution vector; `envconf.py` reads line by line and strips one layer of matching quotes
- `wewrite`: `config-info` (`--json`) prints every resolved value, the layer that supplied it, and whether each search location exists — including redacted secrets. `out-dir` prints the resolved output directory. Debugging "it wrote to the wrong place" is one command
- `wewrite`: `--init` detects `VAULT_DIR` and merges per key so sibling skills' entries and user comments survive a re-run; `--init --dry-run` changes nothing on disk and writes a timestamped `.bak` before the first real mutation
- `wewrite`: the interpreter is discovered by probing for the actual dependencies (`pyyaml`, `requests`, `markdown`, `bs4`, `cssutils`, `pygments`, `Pillow`) rather than guessing from a path — macOS ships a `python3` without `yaml`. `--setup` builds a local `.venv`; a missing interpreter exits 3 with the reason instead of a traceback

### Fixes
- `wewrite`: `learn-edits` resolved recorded article paths against the state root, so it would have failed to find drafts that now live in the vault. Follows the same output-root rule as `runs.py`
- `wewrite`: `diagnose` reports `out_dir` alongside `home`, so an agent can see where output goes without a second command

### Notes
- The vendored copy is versioned `4.2.1-mario.1` in `skills/wewrite/VERSION`, deliberately off the upstream tag. Syncing upstream means hand-merging `paths.py` and `envconf.py`; `toolkit/config.py` only gained the `.env` import
- `raw/` is defined as immutable source material in this vault's `CLAUDE.md`, so output defaults to `output/WeWrite/` — the directory that vault already reserves for generated content. Targeting `02-Output/02-Platforms/微信公众号` instead is one line of config (`WEWRITE_OUT_SUBDIR`), not a code change
- The pre-existing upstream install at `~/.claude/skills/wewrite*` (symlinks into `~/.cc-switch/skills/wewrite/`) is still active and will shadow or duplicate this skill. Remove it, or the agent may load the unported copy.

## 0.7.0 - 2026-10-18

### Features
- `dankoe-letters-fetch`: incremental fetch of Dan Koe's newsletter into `raw/DanKoe/原文/`. Dedup keys on the exact URL slug; Substack republish suffixes (`-ef8`) are different articles and still get fetched
- `dankoe-letters-fetch`: config moved onto the shared `.mario-skills/.env`. `VAULT_DIR` is the same key the other three skills already use — one write, four skills. Keys: `DANKOE_OUT_SUBDIR`, `DANKOE_SESSION`, `DANKOE_COUNT`, `DANKOE_STATE_DIR`, `OPENCLI_BIN`
- `dankoe-letters-fetch`: `--init` / `--init --project` / `--init --dry-run` / `--detect` / `--config-info` (`--json`), config merged per key so sibling skills' keys and user comments survive a re-run
- `dankoe-letters-fetch`: the four Substack API constraints are now code rather than prompt prose — the `limit=23` clamp, `body_html` being null in listings, `audience` as the only reliable paywall signal, and exact-slug dedup. None of them error when violated; they silently produce wrong results
- `dankoe-letters-fetch`: stdout is one JSON receipt per subcommand; human-readable output moved to stderr

### Fixes
- `dankoe-letters-fetch`: **dedup was silently dead.** The skill read `00-Raw/DanKoe/原文/` but the vault reorganization on 2026-10-12 moved the real output to `raw/DanKoe/原文/`. The scan found an empty directory, so every run re-fetched all 95 articles. Now points at `raw/DanKoe/`, with a note in `env.shared.example` to keep the two in sync
- `dankoe-letters-fetch`: any per-article failure now exits 1, so cron and launchd notice
- `dankoe-letters-fetch`: the failure log moved out of the skill directory to `$DANKOE_STATE_DIR`, and a stale one is deleted after a clean run
- `dankoe-letters-fetch`: `--dry-run` is documented honestly. It still needs network (the archive is an HTTP API) but opens no browser and writes nothing
- `dankoe-letters-fetch`: `opencli` is only required for `fetch`. `list` enumerates over plain curl and works without the browser bridge

### Notes
- `exhausted: true` means "the archive is caught up", not "vault and archive agree". Measured 2026-10-18: 95 articles in the vault, 91 in the archive, and 5 of those return `Post not found` on both the archive and the single-post endpoint — deleted upstream.
- The previous skill at `~/.claude/skills/dankoe-letters-fetch/` still points at the dead `00-Raw/` path. Remove or repoint it, or the agent will keep loading the broken copy.

## 0.6.0 - 2026-10-18

### Features
- `dedao-course-sync`: incremental sync of the 得到 精选 / 得到头条 columns into `raw/Courses-GetIt/`. Dedupe keys on Dedao's `article_id` (frontmatter), not the filename, so a renamed title never re-fetches
- `dedao-course-sync`: config moved onto the shared `.mario-skills/.env`. `VAULT_DIR` is the same key `diary-writer` and `book-enquire-reader` already use — one write, three skills. Keys: `DEDAO_OUT_SUBDIR`, `DEDAO_SESSION`, `DEDAO_COUNT`, `DEDAO_STATE_DIR`, `OPENCLI_BIN`
- `dedao-course-sync`: `--init` / `--init --project` / `--init --dry-run` / `--detect`, config merged per key so sibling skills' keys and user comments survive a re-run
- `dedao-course-sync`: `--config-info` (`--json`) reports each resolved value plus the layer that supplied it; missing-config errors enumerate every location searched
- `dedao-course-sync`: stdout is now exactly one JSON receipt per subcommand; all human-readable progress moved to stderr. Callers parse `stdout` instead of scraping prose

### Fixes
- `dedao-course-sync`: a partial failure used to exit 0 — `1 if failed and not saved else 0` meant "20 fetched, 17 saved, 3 failed" reported success, and cron or launchd never retried the three. Any failure now exits 1
- `dedao-course-sync`: `--dry-run` no longer creates the output directory. The `mkdir` ran before the dry-run check, so a dry run mutated the vault
- `dedao-course-sync`: the failure log moved from `scripts/.dedao-sync-errors.json` to `$DEDAO_STATE_DIR/dedao-sync-errors.json`. A marketplace-installed skill directory may be read-only, and runtime state does not belong in a code directory
- `dedao-course-sync`: a stale failure log is deleted after a fully successful run
- `dedao-course-sync`: `SKILL.md` claimed `--dry-run` "does not touch the browser". It does — the pending list comes from that JSON endpoint. What it guarantees is "writes no files", and the docs now say so
- `dedao-course-sync`: the report label `跳过(同名)` was misleading. Dedup already ran on `article_id`, so that branch means a genuinely new article whose cleaned filename collided with an existing one. Now `跳过(slug 撞车)`
- `diary-writer`: fixed a broken `LICENSE.md` link in `README.md`

### Notes
- `dedao-course-sync` keeps `VAULT`, slug-cleaning tables and body anchors as code rather than config. They travel as a set: swapping only the course ID leaves the slug rules and `body_anchor` mismatched, which produces files that are wrong but look fine.
- Removed dead supersedes: `02-Output/03-Tools/scripts/dedao-{scrape,init,daily,convert-article,inject-image-urls}` and the `dedao-scrape` test fixture, plus the empty `10-Claude/skills/dedao-course-sync/` directory. The three skills in `~/.claude/dedao-skills-retired-2026-09-14.tar.gz` (course / jingxuan / toutiao scrapers) now live in the vault at `02-Output/03-Tools/_archive/` rather than only in `~/.claude`.

## 0.5.0 - 2026-10-15

### Breaking changes
- `book-enquire-reader`: `BOOKS_SUBDIR` 默认值从 `books` 改为 `raw/books`。新书默认落在 `<vault>/raw/books/<category>/<slug>/_source/`，与 vault 现有 `raw/` 素材区对齐。已在 `.env` 里显式设过 `BOOKS_SUBDIR=books` 的用户不受影响；manifest 按绝对路径键控，新旧两套目录独立运行不冲突
- `book-enquire-reader`: 6 格式白名单。`SUPPORTED_EXT` 收窄到 `pdf|epub|mobi|txt|text|md`，其它格式（HTML / AZW3 / AZW / PRC / HTML / XHTML / Markdown 重复别名）一律返回 `unsupported_format`。原 HTML/AZW3 用户需要先转 EPUB/PDF，或用其它 skill

### Features
- `book-enquire-reader`: 路径范围硬检查。`do_import` 校验 source 文件必须在 `<VAULT_DIR>/<BOOKS_SUBDIR>` 下，否则返回 `scope_error`（defense-in-depth，Phase 0 §0.1 应当先把文件 cp 到 `incoming/`）
- `book-enquire-reader`: `--init` 写完 `.env` 后自动 `mkdir -p <VAULT_DIR>/<BOOKS_SUBDIR>`，确保首次运行后书籍目录就位（dry-run 模式不落盘）
- `book-enquire-reader`: Phase 0 §0.1 新增"预检 + 保存"段。LLM 收到文件先做格式白名单 + 路径范围检查：vault 外文件 `cp -p` 到 `raw/books/incoming/`，vault 内但非书籍路径的文件直接跳过，6 格式以外的文件交回其它 skill
- `book-enquire-reader`: `book_admin.sh status` 同时打印 `Books folder`（相对）与 `Books root (abs)`（绝对）两个字段，方便排查"我的书为什么没在 raw/books 下"

### Notes
- 现有 `<vault>/books/`（如存在）保留不动，新书走 `<vault>/raw/books/`，两条路径独立运行、manifest 各管各的
- Phase 0 已存在的 `imported / skip_unchanged` 行为不变；新引入的 `scope_error` 是路径范围错误的明确信号（script 与 SKILL.md §0.1 双重防御）
- description 已同步收窄到 6 格式：原 HTML/AZW3 触发词会让 agent 误读为本书籍 skill 的活；0.5+ 起 description 明示"非 6 格式属其它 skill 领地"

## 0.4.0 - 2026-10-15

### Features
- `book-enquire-reader`: Phase 0 Auto-Ingest. 当用户消息只含 PDF/EPUB/TXT/Markdown/MOBI/AZW3/HTML 附件而无说明文字时，自动入库 + 精读第一章 + TOC + 3 核心洞察（原子化，对齐 `snowball-tracker` 的"一次一份"哲学）。已存在且 SHA-256 未变的书直接回执"已导入，未重复精读"，不调 MCP
- `book-enquire-reader`: 新配置 `BOOK_AUTO_INGEST` (默认 `true`) 控制 Phase 0 开关；`BOOK_AUTO_INGEST_MAX` (默认 `1`) 限制单条消息自动处理本数，防批量拖入时 token 雪崩

### Notes
- 显式触发场景（"读这本书 / 继续 / 读第 N 章"）的 4 阶段管线**未变更**，Phase 0 仅是新增的入口前置
- `skip_unchanged` 在两种模式下语义不同：Phase 0 下 = 不再精读；显式触发下 = 仍可走 Phase 1（结构 + 重写笔记）
- description 末尾 NOT 子句排除日记 / 截图识别 / 微信文章场景，避免误触发

## 0.3.0 - 2026-10-14

### Features
- `book-enquire-reader`: long-book reader. Imports PDF/EPUB/TXT/Markdown into the vault and drives [enquire-mcp](https://github.com/oomkapwn/enquire-mcp) hybrid retrieval to produce chapter digests carrying `[page: N]` citations, without pulling whole chapters into context
- `book-enquire-reader`: `--init` / `--init --project` / `--detect` / `--dry-run`, config merged per key so sibling skills' keys and user comments survive a re-run
- `book-enquire-reader`: `book_extract.py` converts EPUB (via the OPF spine, so chapter order is the author's), TXT (CJK and English chapter markers), and HTML to Markdown. Stdlib only; MOBI converts when `ebook-convert`/`kindlegen` is present and fails with an actionable message when it is not
- `book-enquire-reader`: SHA-256 incremental import — an unchanged book returns `skip_unchanged` instead of re-extracting; `--dry-run` reports the plan without touching disk
- `book-enquire-reader`: `book_admin.sh status | list | verify | remove`. `status` reports whether PDF blending, the embedding index, and OCR are actually available; `verify` compares the manifest against disk and flags hash drift
- `book-enquire-reader`: `--config-info` (`--json` for machine use) reports every resolved value plus the layer that supplied it; missing-config errors enumerate every location searched

### Notes
- `book-enquire-reader` uses `BOOK_STATE_DIR`, not `STATE_DIR`. `STATE_DIR` belongs to `diary-writer`; sharing one key would have collided their hash and backup directories.
- Retrieval is confined to `<BOOKS_SUBDIR>/<category>/<slug>/<BOOK_SOURCE_SUBDIR>` and digests are written to a sibling `notes/`. enquire indexes every markdown in the vault via a watcher, so co-locating them would make chapter N retrieve chapter 1–N-1's summaries instead of the source text — and their inherited `[page: N]` markers would become citations to pages never read.

## 0.2.0 - 2026-10-08

### Breaking changes
- `diary-writer`: `~/.config/diary-obsidian/config.ini` is no longer read. `.mario-skills/.env` is now the single config file for every skill, so configuration no longer spans two formats. Migrate by moving the file — both grammars are identical, so no key needs renaming:
  ```bash
  mkdir -p ~/.mario-skills
  mv ~/.config/diary-obsidian/config.ini ~/.mario-skills/.env
  ```
- `diary-writer`: `--config PATH` removed — it only ever pointed at a `config.ini`. It now exits with a message pointing at `--config-info`.
- `diary-writer`: `--init --env` removed. With one config surface the flag was redundant; `--init` writes `~/.mario-skills/.env` and the new `--init --project` writes `<cwd>/.mario-skills/.env`.

### Features
- `diary-writer`: `--init --project` writes the project-level `.env`, for a single vault scoped to one directory
- `diary-writer`: resolution chain is now process env → project `.env` → user `.env` → built-in defaults
- `mario-skills`: `examples/env.shared.example` documents the shared file; the per-skill `config.minimal.ini` / `config.full.ini` examples are gone

### Fixes
- `diary-writer`: values are trimmed without collapsing internal whitespace, so paths containing spaces (e.g. `Mobile Documents`) round-trip unchanged

## 0.1.0 - 2026-10-07

### Features
- `mario-skills`: marketplace scaffold — single-plugin manifest, bilingual README, author guide, and a validator that fails when a skill directory is not registered
- Shared `.env` convention: every skill reads `<project>/.mario-skills/.env` and `~/.mario-skills/.env`, so a key is written once and all skills see it. Values are parsed, never `source`d, so a credentials file cannot execute code. Both locations gitignored
- `diary-writer`: append-only journal writer for local markdown vaults. ISO week numbering, MD5 dedup, pre-write backups, JSON receipts on stdout
- `diary-writer`: `--config-info` (`--json` for machine use) reports each resolved value plus the layer that supplied it and whether each search location exists — one command replaces guessing when the vault looks wrong
- `diary-writer`: missing-config errors enumerate every location searched in a `searched` array
- `diary-writer`: `--init` pre-fills the wizard from currently resolved values, so re-running it shows your live config instead of built-in defaults
