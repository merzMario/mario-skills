# Changelog

All notable changes to this marketplace. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [semver](https://semver.org/spec/v2.0.0.html).

The version here is the single source of truth — it lives in `metadata.version` in
`.claude-plugin/marketplace.json` and is what users receive on marketplace update.

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
