# book-enquire-reader

中文 | [English](./README.md)

Long-book reading and note extraction. The book stays in the Obsidian vault, indexed by [enquire-mcp](https://github.com/oomkapwn/enquire-mcp); the agent pulls only the slices it needs — so a 300-page book costs about what a 30-page one costs.

## Why this exists

Two common approaches do not survive contact with a long book.

**Loading the whole book into context.** A 300-page PDF is roughly 200K tokens. It eats the window in one call, and it does not help the next chapter: later analysis cannot refer back to earlier text that has already scrolled away.

**Keeping only a summary.** A summary without provenance cannot be checked, and cannot be traced back to the source when a detail matters.

This skill keeps the book in the vault as the single source of truth, lets the retrieval layer serve slices on demand, and carries only the retrieved fragments into context. Every claim keeps its original page number, so the source can always be re-read.

## Architecture

```
                       ┌──────────────────────────────────────────┐
  ~/Books/x.epub ─────▶ │ book_import.sh                            │
                       │  · EPUB/TXT/MOBI/HTML → Markdown           │
                       │  · PDF/MD copied verbatim                 │
                       │  · SHA-256 incremental detection          │
                       │  · backup before overwrite                │
                       └───────────────┬──────────────────────────┘
                                       │ receipt JSON carries search_folder
                                       ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │ Obsidian vault                                                     │
  │  books/<category>/<slug>/                                          │
  │    ├── _source/   ◀── retrieval scope; folder= points only here    │
  │    │     ├── original.epub                                         │
  │    │     └── <slug>.md   (## chapter headings align the chunks)    │
  │    └── notes/     ◀── digests; retrieval never enters              │
  │          ├── Chapter_01_xxx.md   with [page: N]                    │
  │          └── Index_Concepts.md                                     │
  └────────────────────────────┬───────────────────────────────────────┘
                               │ watcher indexes automatically
                               ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │ enquire-mcp  BM25 + TF-IDF + vectors → RRF fusion                   │
  │  obsidian_search / obsidian_hyde_search / obsidian_read_pdf          │
  └────────────────────────────┬───────────────────────────────────────┘
                               │ folder=search_folder on every call
                               ▼
                          Agent digests → writes back to notes/
```

**The physical separation of `notes/` and `_source/` is what makes this correct**, not a stylistic choice. enquire indexes any markdown in the vault through a watcher; if digests and source text share a directory, chapter 7's retrieval returns chapter 1–6's summaries instead of the original — compounding as the book goes on, and turning the digests' inherited `[page: N]` markers into citations to pages nobody read.

## Quickstart

### 1. Install the dependency

```bash
npm install -g @oomkapwn/enquire-mcp
# EPUB/TXT extraction uses only the Python standard library — no pip install
```

### 2. Initialize config (once, by a human)

```bash
bash scripts/book_import.sh --detect    # list the vaults on this machine
bash scripts/book_import.sh --init      # writes ~/.mario-skills/.env
```

### 3. Start enquire-mcp (the flags matter)

```bash
enquire-mcp serve --vault ~/Documents/Obsidian \
  --enable-write --include-pdfs --persistent-index
```

Then build the index (one-time, slow on CPU):

```bash
enquire-mcp setup --vault ~/Documents/Obsidian
```

Each `serve` flag buys one capability, and omitting one degrades silently rather than erroring. [`SKILL.md`](./SKILL.md) section 1 has the full mapping.

### 4. Import and read

```bash
# import (a second run of the same file returns skip_unchanged)
bash scripts/book_import.sh --book ~/Books/Thinking-Fast-and-Slow.epub --category psychology

# confirm the retrieval layer is usable
bash scripts/book_admin.sh status
```

Then ask Claude Code: "read this book and pull out the key concepts".

### 5. Auto-ingest (file-only trigger)

From v0.4: drop or attach a PDF/EPUB/TXT/Markdown/MOBI/AZW3/HTML file with **no accompanying text**, and the agent will automatically:

1. Call `book_import.sh` to import
2. Digest chapter 1 + generate TOC + extract 3 core insights
3. Write `notes/Chapter_01_xxx.md` + `README.md`

Follow-up commands:

- "继续" → expand the rest of the chapters (Phase 2 loop)
- "读第 N 章" → jump to a specific chapter
- Re-send the same book → SHA-256 unchanged, reply "already imported, not re-digested"

Limit: when multiple books arrive in one message, only the first `BOOK_AUTO_INGEST_MAX` (default 1) are auto-handled. Don't want it? Say "不要自动精读" once to disable (see `BOOK_AUTO_INGEST`).

## Configuration

Everything resolves through the shared `.mario-skills/.env` — the marketplace-wide convention. No separate config format:

| Key | Default | Meaning |
|-----|---------|---------|
| `VAULT_DIR` | — | Vault root. Same key `diary-writer` uses — set it once |
| `BOOKS_SUBDIR` | `raw/books` | Where book folders live (relative to VAULT_DIR; default aligns with the vault's `raw/` materials area per CLAUDE.md) |
| `BOOK_SOURCE_SUBDIR` | `_source` | **Retrieval scope.** Every `folder=` points here |
| `BOOK_NOTES_SUBDIR` | `notes` | Digest notes, deliberately outside the retrieval scope |
| `BOOK_HYDE` | `true` | Use `obsidian_hyde_search` |
| `BOOK_GRAPH` | `true` | Use `obsidian_get_communities` |
| `BOOK_OCR` | `false` | OCR for scanned PDFs (also needs a server-side language pack) |
| `BOOK_MAX_CHUNKS` | `5` | Ceiling on `limit` per query — the context-token hard stop |
| `BOOK_ENQUIRE_BIN` | `enquire-mcp` | The enquire-mcp executable |
| `BOOK_STATE_DIR` | `~/.local/share/book-enquire-reader` | Import manifest and backups |
| `BOOK_AUTO_INGEST` | `true` | Phase 0 auto-ingest switch (fires on file-only messages) |
| `BOOK_AUTO_INGEST_MAX` | `1` | Cap on auto-digests per message (defensive default against batched uploads) |

Resolution order: `process.env` → `<project>/.mario-skills/.env` → `~/.mario-skills/.env` → built-in defaults. Resolved **per key**: setting only `VAULT_DIR` does not reset the rest. Unknown keys are ignored, so one file serves every skill.

To find out where a value came from:

```bash
bash scripts/book_import.sh --config-info
bash scripts/book_admin.sh --config-info --json
```

See [`examples/env.shared.example`](./examples/env.shared.example) for the annotated file.

## Commands

```bash
# import
bash scripts/book_import.sh --book <path> [--slug <name>] [--category <name>]
bash scripts/book_import.sh --book <path> --dry-run      # preview only
bash scripts/book_import.sh --book <path> --force        # re-import changed content

# admin
bash scripts/book_admin.sh status     # is the retrieval layer actually usable?
bash scripts/book_admin.sh list       # what has been imported
bash scripts/book_admin.sh verify     # does disk agree with the manifest?
bash scripts/book_admin.sh remove <slug> [--delete] [--dry-run]

# standalone conversion
python3 scripts/book_extract.py book.epub -o out.md
```

`--init` and `--detect` are for a human at a terminal — never call them from an LLM.

## Known limitations

**Formats.** enquire-mcp natively reads PDF and Markdown. EPUB / TXT / HTML go through `book_extract.py`; MOBI needs an external converter (`brew install calibre` ships `ebook-convert`) and errors with an actionable message when none is present. A scanned PDF has no text layer, is not extracted, and needs OCR.

**EPUB chapter order.** Correct EPUBs are read through the OPF spine, which is the author's order. When the spine is damaged the extractor falls back to archive order and chapter order may be wrong; it says so on stderr.

**CJK filenames.** Slugs keep ASCII only, so a Chinese filename needs an explicit `--slug <pinyin-or-english>`.

**`obsidian_get_communities` takes no `folder`.** It partitions the whole vault's wikilink graph, so the agent must filter `communities[].members` by path prefix itself. With one book in the vault it carries almost no information.

**Embeddings truncate at 128 tokens.** The default multilingual model embeds only the first 128 tokens of a chunk, while FTS5 chunks run 600–1000 tokens. Long paragraph tails are reachable through the lexical channel but not the vector one. This is an enquire-mcp model limit, not a limitation of this skill.

**No automatic reindex.** `build-embeddings` encodes the entire vault — O(vault) per call, not O(new book). Importing ten books in a row means ten full-vault encodes. Pass `--reindex` when you want one, or run it once after a batch.

**Read-only with respect to the source.** Nothing in this skill ever modifies `_source/`.

## License

MIT — see [LICENSE](./LICENSE).