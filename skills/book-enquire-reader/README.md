# book-enquire-reader

[English](./README.en.md) | 中文

长书深度阅读与笔记提炼。原文留在 Obsidian vault 里由 [enquire-mcp](https://github.com/oomkapwn/enquire-mcp) 索引，Agent 按需拉取切片 —— 300 页的书和 30 页的书消耗差不多的上下文。

## Why this exists

两种常见做法都不可持续：

**把整本书读进上下文。** 一本 300 页 PDF 约 200K token，一次就吃掉大部分窗口，而且读完就忘 —— 后面章节的分析无法参考前面的内容。

**只留一份摘要。** 摘要一旦丢失出处就无法核验，也无法在需要细节时回溯原文。

这个 skill 的做法是把书留在 vault 里作为**唯一事实来源**，检索层负责按需切片，Agent 只把切出来的片段带进上下文。所有结论保留原始页码，可以随时回原文核对。

## 架构

```
                       ┌──────────────────────────────────────────┐
  ~/Books/x.epub ─────▶ │ book_import.sh                            │
                       │  · EPUB/TXT/MOBI/HTML → Markdown           │
                       │  · PDF/MD 原样落盘                         │
                       │  · SHA-256 增量检测，重复导入直接跳过        │
                       │  · 覆盖前备份                              │
                       └───────────────┬──────────────────────────┘
                                       │ 回执 JSON 带 search_folder
                                       ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │ Obsidian vault                                                     │
  │  books/<category>/<slug>/                                          │
  │    ├── _source/   ◀── 检索范围，folder= 只指这里                     │
  │    │     ├── original.epub                                         │
  │    │     └── <slug>.md   (## 章节标题对齐切片边界)                   │
  │    └── notes/     ◀── 提炼笔记，检索永不进入                         │
  │          ├── Chapter_01_xxx.md   带 [page: N]                        │
  │          └── Index_Concepts.md                                     │
  └────────────────────────────┬───────────────────────────────────────┘
                               │ watcher 自动索引
                               ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │ enquire-mcp  BM25 + TF-IDF + 向量 → RRF 融合                        │
  │  obsidian_search / obsidian_hyde_search / obsidian_read_pdf          │
  └────────────────────────────┬───────────────────────────────────────┘
                               │ 每次都传 folder=search_folder
                               ▼
                          Agent 提炼 → 回写 notes/
```

**`notes/` 和 `_source/` 的物理隔离是这个 skill 正确性的前提**，不是风格偏好。enquire 会自动索引写进 vault 的任何 markdown；如果提炼笔记和原文同处一个目录，第 7 章的检索会命中第 1–6 章的摘要而不是原文，越读越偏，而且摘要里带的 `[page: N]` 会变成无法核验的伪引用。

## Quickstart

### 1. 安装依赖

```bash
npm install -g @oomkapwn/enquire-mcp
python3 -c "import zipfile"   # EPUB/TXT 抽取只用标准库，无需 pip 安装
```

### 2. 初始化配置（一次，人工）

```bash
bash scripts/book_import.sh --detect    # 看看本机有哪些 vault
bash scripts/book_import.sh --init      # 写入 ~/.mario-skills/.env
```

### 3. 启动 enquire-mcp（参数不能省）

```bash
enquire-mcp serve --vault ~/Documents/Obsidian \
  --enable-write --include-pdfs --persistent-index
```

然后建索引（一次性，CPU 上很慢）：

```bash
enquire-mcp setup --vault ~/Documents/Obsidian
```

三个 `serve` 参数各自对应一条能力，缺了不会报错、只会静默降级 —— 详见 [`SKILL.md`](./SKILL.md) 第一节的对照表。

### 4. 导入并阅读

```bash
# 导入（第二次跑同一本书会返回 skip_unchanged）
bash scripts/book_import.sh --book ~/Books/思考，快与慢.epub --slug thinking-fast-slow --category psychology

# 确认检索层可用
bash scripts/book_admin.sh status
```

然后在 Claude Code 里说"帮我读一下 thinking-fast-slow 这本书"。

### 5. 自动入库（无文字触发）

v0.4 起：直接拖入/附加一本 PDF/EPUB/TXT/Markdown/MOBI/AZW3/HTML 文件，
**不带任何说明文字**时，agent 会自动：

1. 调用 `book_import.sh` 入库
2. 精读第一章 + 生成 TOC + 提炼 3 条核心洞察
3. 写 `notes/Chapter_01_xxx.md` + `README.md`

后续指令：

- "继续" → 展开剩余章节（Phase 2 循环）
- "读第 N 章" → 跳读到指定章节
- "再发一次同一本书" → SHA-256 未变，回执"已导入，未重复精读"

限制：单条消息多本书时，只自动处理前 `BOOK_AUTO_INGEST_MAX` 本（默认 1）。
不想自动跑？加一句 "不要自动精读" 即可关闭（见配置 `BOOK_AUTO_INGEST`）。

## 配置

全部配置走共享的 `.mario-skills/.env`（marketplace 统一约定），不额外造配置文件格式：

| 键 | 默认 | 说明 |
|----|------|------|
| `VAULT_DIR` | — | vault 根目录。与 `diary-writer` 共用同一个键，写一次两边都看到 |
| `BOOKS_SUBDIR` | `raw/books` | 书籍根目录（vault 相对路径，默认 `raw/books` 与 vault 的 `raw/` 素材区对齐） |
| `BOOK_SOURCE_SUBDIR` | `_source` | **检索范围**。所有 `folder=` 指向这里 |
| `BOOK_NOTES_SUBDIR` | `notes` | 提炼笔记目录，刻意放在检索范围之外 |
| `BOOK_HYDE` | `true` | 是否用 `obsidian_hyde_search` |
| `BOOK_GRAPH` | `true` | 是否用 `obsidian_get_communities` |
| `BOOK_OCR` | `false` | 扫描版 PDF 是否 OCR（另需服务端装语言包） |
| `BOOK_MAX_CHUNKS` | `5` | 单次检索切片数上限，即 context token 硬闸 |
| `BOOK_ENQUIRE_BIN` | `enquire-mcp` | enquire-mcp 可执行文件 |
| `BOOK_STATE_DIR` | `~/.local/share/book-enquire-reader` | 导入清单与备份 |
| `BOOK_AUTO_INGEST` | `true` | 是否启用 Phase 0 自动入库（仅文件无文字触发） |
| `BOOK_AUTO_INGEST_MAX` | `1` | 单条消息最多自动精读几本（防批量拖入时 token 雪崩） |

解析优先级：`process.env` → `<项目>/.mario-skills/.env` → `~/.mario-skills/.env` → 内置默认值。**逐 key 独立解析** —— 只设 `VAULT_DIR` 不会让其他键丢失。本 skill 不认识的键会被忽略，所以一个 `.env` 可以同时服务所有 skill。

查某个值从哪来：

```bash
bash scripts/book_import.sh --config-info
bash scripts/book_admin.sh --config-info --json
```

完整样例见 [`examples/env.shared.example`](./examples/env.shared.example)。

## 命令

```bash
# 导入
bash scripts/book_import.sh --book <path> [--slug <name>] [--category <name>]
bash scripts/book_import.sh --book <path> --dry-run      # 只预演，不落盘
bash scripts/book_import.sh --book <path> --force        # 内容变了强制重导

# 管理
bash scripts/book_admin.sh status     # 检索层是否真的可用
bash scripts/book_admin.sh list       # 已导入清单
bash scripts/book_admin.sh verify     # 磁盘与清单是否一致
bash scripts/book_admin.sh remove <slug> [--delete] [--dry-run]

# 格式转换（可独立使用）
python3 scripts/book_extract.py book.epub -o out.md
```

`--init` / `--detect` 是给人跑的命令，不要从 LLM 调用里执行。

## 已知边界

**格式。** enquire-mcp 原生只读 PDF 和 Markdown。EPUB / TXT / HTML 由 `book_extract.py` 转成带 `##` 章节标题的 Markdown；MOBI 需要外部转换器（`brew install calibre` 提供 `ebook-convert`），没有就报错，不会静默产出空文件。扫描版 PDF 没有文本层，PDF 不会被抽取，需要 OCR。

**EPUB 章节顺序。** 正常 EPUB 按 OPF spine 读取，即作者顺序。spine 损坏时退回按归档顺序，章节顺序可能不对。`book_extract.py` 在这种情况下会在 stderr 说明。

**中文书名。** slug 化只保留 ASCII，中文文件名导入会报 `slug_undetermined`，需要显式传 `--slug <英文或拼音名>`。

**`obsidian_get_communities` 没有 folder 参数。** 它对整个 vault 做社区划分，Agent 必须自己按路径前缀过滤。全库只有一本书时它几乎没有信息量。

**嵌入模型 128 token 截断。** 默认 multilingual 模型只嵌入前 128 token，而 FTS5 切片约 600–1000 token。长段落尾部不参与向量检索，词法通道仍能命中。这是 enquire-mcp 的模型限制，不是本 skill 的。

**每次导入后的索引。** 默认**不**自动重建。`build-embeddings` 编码的是整个 vault，O(vault) 而非 O(新书)，连续导入 10 本书意味着 10 次全库编码。要建就显式 `--reindex`，或者在批量导入完成后手动跑一次。

**只写笔记，不改原文。** 本 skill 从不修改 `_source/` 里的内容。

## License

MIT — 见 [LICENSE](./LICENSE)。