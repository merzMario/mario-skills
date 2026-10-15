---
name: book-enquire-reader
description: 长书深度阅读与笔记提炼。把 PDF/EPUB/MOBI/TXT/MD/TEXT 6 种格式的书籍导入 Obsidian vault 的 `raw/books/<category>/<slug>/`，用 enquire-mcp 本地混合检索按需切片，产出带 [page: N] 页码溯源的分章笔记与知识图谱，全程不把整本书读进上下文。触发于以下任一场景：(a) 用户只发送/附加书籍文件而无任何说明文字——自动入库+精读第一章+TOC+3 核心洞察；(b) 用户说"读这本书 / 帮我读书 / 读书笔记 / 精读这本书 / 分析这本书 / 提炼知识点 / 拆书 / summarize this book / read this PDF / extract knowledge from book / 继续 / 读第N章"；(c) 用户直接给出书籍文件路径要求产出笔记/摘要/知识点。不用于日记、截图识别、微信文章，或非 6 格式（HTML/AZW3/Markdown 等）场景——后两类属其它 skill 的领地。
---

# book-enquire-reader

> 面向超长书籍的低 token 阅读器。原文留在 vault 里由 enquire-mcp 索引，Agent 只按需拉切片。

---

## 0、Phase 0: Auto-Ingest（仅文件触发，无文字）

> **触发条件**：用户消息里**只有**附件（PDF/EPUB/TXT/Markdown/MOBI/AZW3/HTML），
> 没有任何用户自己的文字。识别为附件即跑本节，不问、不等、不引导。
> 多文件 / 多书 → 只自动处理前 `BOOK_AUTO_INGEST_MAX` 本（默认 1），其余转交用户指令。

### 0.1 预检 + 保存（LLM 侧，不调任何脚本）

**v0.5+ 新增**：收到附件**先**做两步预检，**不**直接 `book_import.sh`。

**1. 格式白名单** —— 文件扩展名 ∈ {pdf, epub, mobi, txt, text, md}？
不在 → **终止 Phase 0**，不回执（其它 skill 接管，不要替它们做"我帮你转一下"）。

**2. 路径范围** —— `BOOK_RAW_DIR = <VAULT_DIR>/<BOOKS_SUBDIR>`（默认 `<vault>/raw/books/`，见 §1.1）：

| 文件位置 | 处理 |
|---------|------|
| 已在 `BOOK_RAW_DIR` 内（含 `incoming/`、`<category>/<slug>/_source/` 等任意深度） | 直接进 0.2（调 book_import.sh） |
| 在 vault 内但不在 `BOOK_RAW_DIR`（如 `wiki/`, `assets/`, `10-Claude/`, `journals/`） | **终止 Phase 0**，回执 "不在书籍目录（<相对路径>），跳过" |
| 在 vault 外（`~/Downloads/`, `/tmp/`, `/Users/...` 等） | `mkdir -p "$BOOK_RAW_DIR/incoming" && cp -p <原文件> "$BOOK_RAW_DIR/incoming/<filename>"`，用**新路径**进 0.2 |

`incoming/` 是 Phase 0 的中转站，落进后由 `book_import.sh` 完成 `<category>/<slug>/_source/` 的结构化落盘。**不**用 `mv`、**不**改原文件。

### 0.2 调用 `book_import.sh`

```bash
bash "${SKILL_DIR}/scripts/book_import.sh" --book "<已进入 BOOK_RAW_DIR 的路径>"
```

回执处理（JSON 三分支 + 范围错误）：

| `action`                          | Agent 动作 |
|-----------------------------------|------------|
| `imported` / `imported_extracted` | 入库成功 → 直接进 0.3 |
| `skip_unchanged`                  | 书已在库 → **终止 Phase 0**，回执 "已导入，未重复精读（路径 X）"，**不**调任何 MCP |
| `error:"scope_error"`             | 文件不在 `BOOK_RAW_DIR` 下 → **回执错误，停止**（说明 0.1 预检漏了） |

其它 (`error:*`) 走第五节错误处理表。

> 走完 0.2 后 `search_folder` 已在手。**永远不要**给 `obsidian_search` 漏掉 `folder=`，详见 1.2。

### 0.3 精读第一章 + TOC + 3 核心洞察（一次性原子动作）

按顺序一次性完成四件事，**不**展开 Phase 2 全书循环：

1. **TOC 定位** —— PDF 走 `obsidian_read_pdf(pages=[1,15])`；其它格式走
   `obsidian_search(folder=search_folder, query="目录 章节 序言", limit=5)`。
   产出章节列表，写入 `raw/books/<category>/<slug>/README.md` 的"全书大纲"段。
2. **第一章定向切片** —— `obsidian_search(folder=search_folder, query=<第一章标题/假设>,
   limit=BOOK_MAX_CHUNKS)`；欠明确用 `obsidian_hyde_search` 兜底。
3. **结构化提炼** —— 写 `notes/Chapter_01_<标题>.md`（模板见 `templates/chapter-note.md`）。
   每条论点必带原始 `[page: N]`，拿不到页码的进"本章未解决的问题"。
4. **3 核心洞察** —— 写 `raw/books/<category>/<slug>/README.md` 的"全书三大核心洞察"段。
   每条必能指回 Chapter_01 笔记 / 页码；当前仅有第一章数据时，明示"基于第一章"。

### 0.4 回执用户

成功：

```
已入库 + 已精读第一章：<slug>
笔记：books/<category>/<slug>/notes/Chapter_01_xxx.md
TOC + 3 洞察：books/<category>/<slug>/README.md
回复 "继续" 展开全书 / "读第 N 章" 跳读。
```

Skip：

```
已导入，未重复精读：<slug>
（注：之前已入库。SHA-256 未变，自动跳过。）
```

---

## 一、前置：两个必须先确认的前提

### 1.1 enquire-mcp 服务端必须带对启动参数

**这套流程依赖的每一个工具都有服务端开关。缺任何一个，对应阶段会直接失败或静默降级。**

```bash
enquire-mcp serve --vault <VAULT_DIR> \
  --enable-write \      # 阶段二/四写笔记：obsidian_create_note / obsidian_append_to_note 没有它就不存在
  --include-pdfs \      # 阶段一/二的 [page: N] 页码溯源：PDF 切片不进混合检索就没有页码
  --persistent-index    # 阶段二：BM25/FTS5 词法通道
```

| 缺失的开关 | 后果 | 症状 |
|-----------|------|------|
| `--enable-write` | 写入工具根本不在工具列表里 | 阶段二第 4 步、阶段四报 "tool not found" |
| `--include-pdfs` | PDF 不参与混合检索 | 搜不到书里任何一页；`obsidian_search` 只命中 vault 里的 md |
| `--persistent-index` | 降级为 TF-IDF 单通道 | 专有名词、长引文命中率骤降（不是报错，更隐蔽） |
| embeddings 未构建 | 只有词法信号 | 换一种说法就检索不到同一切片 |

**不要用 `--disabled-tools` / `--enabled-tools` 把上面任何一个收窄掉。**

需要 OCR 时（扫描版）：`BOOK_OCR=true` 且服务端另需 `enquire-mcp install-ocr-lang <code>`。

> ⚠️ **不要在 LLM 调用里跑 `enquire-mcp setup` / `install-model` / `build-embeddings`。** 它们会下载 ONNX 权重、跑全库编码，是给人跑的慢操作。

### 1.2 检索范围（最重要的单条规则）

**每一次 `obsidian_search` / `obsidian_hyde_search` / `obsidian_context_pack` 都必须传 `folder`。**

`folder` 取自导入回执里的 `search_folder`（形如 `raw/books/<category>/<slug>/_source`，与 §0 的 6 格式白名单 + 路径范围硬检查配套）。

不传 `folder` 会发生什么：enquire 有文件 watcher，会自动索引本 skill 写回 vault 的提炼笔记。于是第 7 章的检索会命中第 1–6 章的**摘要**，而不是原文 —— 越读越偏离，越读越贵。而且摘要里带着 `[page: N]` 标记，会产生"引用洗白"：二手摘要引用了它自己从未读过的页码。

本 skill 用目录结构隔离这个问题，而不是依赖 remember：

```
raw/books/<category>/<slug>/      ← 默认 <BOOKS_SUBDIR>=raw/books，与 vault 的 raw/ 素材区对齐
├── README.md              # 全书大纲 + 知识图谱 + 核心洞察
├── _source/               # ← 检索范围，folder= 指向这里
│   ├── original.epub      # 原始文件（enquire 不解析，留档）
│   └── <slug>.md          # EPUB/TXT 抽取出的正文，带 ## 章节标题
└── notes/                 # ← 提炼笔记，检索永不进入
    ├── Chapter_01_xxx.md
    ├── Index_Concepts.md
    └── Mindmap.md
```

> 默认 `BOOKS_SUBDIR=raw/books`，与 vault 的 `raw/`（CLAUDE.md 规定的"原始素材"区）一致。Phase 0 会把 vault 外文件 `cp` 到 `raw/books/incoming/`，由 `book_import.sh` 完成 `<category>/<slug>/_source/` 的结构化落盘。在 `.env` 里显式设过 `BOOKS_SUBDIR=books` 的用户仍可走旧路径，新旧两套 manifest 独立。

---

## 二、LLM 调用方式

**文件操作全部由 `scripts/` 接管。LLM 只做路由，不自己建目录、不拼路径、不算哈希。**

所有脚本都在本 SKILL.md 所在目录的 `scripts/` 下。**从 SKILL.md 的位置解析该目录**，不要依赖调用时的 CWD —— 用户在 vault 里跑和在别处跑，效果必须一样。

```bash
# 导入（幂等，内容未变则 skip_unchanged）
bash scripts/book_import.sh --book ~/Books/x.epub --category psychology

# 只看会做什么，不落盘
bash scripts/book_import.sh --book ~/Books/x.epub --dry-run

# 检索层是否真的可用（搜不到东西时先跑这个）
bash scripts/book_admin.sh status

# 已导入清单 / 磁盘与清单一致性
bash scripts/book_admin.sh list
bash scripts/book_admin.sh verify
```

回执是 JSON（stdout）。**`search_folder` 字段就是第一、二节说的 `folder` 取值，原样转给检索调用。**

| 回执字段 | 处理 |
|---------|------|
| `ok:false, error:"config_not_found"` | **不要自动跑 `--init`。** 把 `searched` 数组原样转述给用户，让用户跑一次 `bash scripts/book_import.sh --init` |
| `error:"book_not_found"` / `"slug_undetermined"` | 文件路径或文件名有问题，请用户确认；中文文件名必须显式传 `--slug` |
| `error:"extract_failed"` | 见第五节错误处理 |
| `action:"skip_unchanged"` | 书已在库且内容未变，**直接进入阶段一**，不必重新导入 |
| `ok:false` 但进程退出码为 0 | 以 `ok` 字段为准，不要只看退出码 |
| `action:"skip_unchanged"`（Phase 0 模式） | 把 `skip_unchanged` 转述成"已在库，未重复精读"，**不**再调任何 MCP（详见 §0） |
| `ok:false, error:"scope_error"` | 文件不在 `<VAULT_DIR>/<BOOKS_SUBDIR>` 下；§0.1 预检应当已经把文件 cp 进 `incoming/`，见到这个错误说明 LLM 漏了预检步骤 |

> ⚠️ **`--init` / `--detect` 是给人跑的命令，不要在 LLM 调用里执行。** 配置归人管。

---

## 三、检索原语（参数以 enquire-mcp 实际签名为准）

这些是本 skill 会用到的全部工具签名。**参数名写错会直接调用失败，不要凭印象改名。**

### `obsidian_search` — 混合检索，默认入口

| 参数 | 说明 |
|------|------|
| `query` | 必填。多词自然语言效果最好 |
| `folder` | **必传（对本 skill 而言）。** 限定到 `search_folder` |
| `limit` | 上限 100，默认 10。传 `BOOK_MAX_CHUNKS`（默认 5） |
| `min_signals` | 1–3。≥2 表示"多路检索器一致命中"，高精度场景用 2 |
| `filter_frontmatter` | 可选，按 frontmatter 过滤候选池 |

**没有 `top_k` 参数。** 返回 `per_signal: {bm25, tfidf, embeddings}`，用它判断是哪一路在起作用。

### `obsidian_hyde_search` — HyDE，欠明确查询用

| 参数 | 说明 |
|------|------|
| `query` | 必填。**原问题**，仅回显审计 |
| `hypothetical_answer` | 必填。**你生成的 1~3 句假设性答案 —— 真正被 embedding 的是这个** |
| `folder` / `limit` / `min_score` | 同上 |

> ❗ **`hypothetical_answer` 是必填的，`query` 在它非空时完全不参与检索。** 只传 `query` 会参数校验失败。

`query` 与 `hypothetical_answer` 的分工：`query` 告诉服务器"这是在问什么"，`hypothetical_answer` 决定召回什么。所以流程是：

1. 先自己写出 1~3 句"如果答案长这样，它会怎么写"（不看 vault，纯凭先验）
2. `obsidian_hyde_search(query=<原问题>, hypothetical_answer=<那几句>, folder=..., limit=N)`

不要把假设答案塞进 `query` 再传一个空的 `hypothetical_answer` —— 那退化成普通 `obsidian_search`。`BOOK_HYDE=false` 时直接用 `obsidian_search`。

### `obsidian_read_pdf` — 取目录 / 补页码

| 参数 | 说明 |
|------|------|
| `path` | 必填。**vault 相对路径**，即回执 `source` 的完整路径（含 `<BOOKS_SUBDIR>/<category>/<slug>/` 前缀） |
| `pages` | 可选，`[起始, 结束]`，1 起闭区间 |
| `include_metadata` | 默认 true |

返回 `has_text` / `complete` / 每页 `status`。**只有 `complete:true` 且 `has_text:false` 才是"扫描页"，此时才可调 `obsidian_ocr_pdf`。**

### `obsidian_get_communities` — 跨章主题

参数只有 `min_size` 和 `limit`。**没有 `folder`。**

它对**整个 vault** 的 wikilink 图做社区划分。所以：

1. 调 `obsidian_get_communities(min_size=2, limit=50)`
2. **自己过滤** `communities[].members`，只留路径以 `search_folder` 为前缀的成员
3. 过滤后成员数 < 2 的社区丢弃
4. 每个社区读 `representative` 笔记即可，不要通读全部成员

`BOOK_GRAPH=false` 时跳过本阶段。全库只有一本书时它基本没有信息量。

### 写入工具（需 `--enable-write`）

`obsidian_create_note(path, content, frontmatter?, overwrite?)` ·
`obsidian_append_to_note(path|title, content, separator?)`

`obsidian_create_note` 默认 `overwrite=false`，已存在的笔记不会静默覆盖 —— 这是好事，不要随手传 `overwrite=true`。

---

## 四、显式触发的四阶段管线（用户说"读这本书"时走这里）

> 收到**纯文件无文字** → 走 §0 Phase 0。收到**文字 + 文件**或**仅文字** → 走本章。

### 阶段一：定位结构，不读正文

1. 用导入回执拿到 `search_folder` 与 `source`。
2. 若是 PDF：`obsidian_list_pdfs()` 确认存在 → `obsidian_read_pdf(path=<source>, pages=[1,15])` 拿目录页。
   EPUB/TXT/MOBI 已被抽成 md，直接 `obsidian_search(folder=..., query="目录 章节 序言", limit=5)` 定位结构。
3. 生成《阅读路线图》：章节列表 + 每章 1 句核心议题假设。
4. 建 `books/<category>/<slug>/README.md`（骨架见 `templates/book-readme.md`）。

**这一步不允许把任何一章的正文读进上下文。**

### 阶段二：逐章定向提炼

对每一章，循环：

1. **选检索式。** 欠明确的宽泛主题 → HyDE；明确的标题/术语 → 直接 `obsidian_search`。
2. **拉切片。** `limit=BOOK_MAX_CHUNKS`（默认 5），`folder=search_folder`。
3. **结构化提取**，全部保留原始 `[page: N]`：
   - 核心论点（作者的明确主张）
   - 支撑推导（数据、案例、逻辑链）
   - 概念提取（标注为 `[[原子概念]]`）
4. **查重再落笔**：对每个概念先 `obsidian_search(folder=<vault 内概念目录>, query=<概念名>, limit=3)`，Vault 里已有就复用并补双链，不要新建同义笔记。
5. 写入 `notes/Chapter_NN_<标题>.md`（骨架见 `templates/chapter-note.md`）。

> **页码只能来自检索返回。** 拿不到 `[page: N]` 的内容，写进"核心论点"就等于伪造引用。这类内容放进"本章未解决的问题"。

**滚动上下文（防止长书读到后面忘了前面）：** 跨批次只携带**最近 10–15 条知识点**作为上下文，不要携带全部。每处理完 5 章，写一次阶段摘要进 `README.md`，覆盖"到目前为止的主题与论点走向"。300 页的书不这样做，第 10 章时你对第 1–9 章的记忆只剩磁盘文件名。

### 阶段三：图谱融合（`BOOK_GRAPH=true`）

1. 按第三节过滤 `obsidian_get_communities` 的结果。
2. 把跨章节复现的概念汇总进 `README.md`：全局知识图谱、全书三大核心洞察、跨章节概念映射。
3. 每条洞察必须能指回具体章节笔记。

### 阶段四：双链与收尾

1. `obsidian_get_backlinks(path=<新笔记路径>)` 校验与既有知识库的连接。
2. 在 `wiki/log.md` 追加一行：书名、章节数、笔记路径、日期。
3. 向用户返回：书目录路径 + 章节笔记清单 + 三条核心洞察。

---

## 五、错误处理

| 症状 | 原因 | 动作 |
|------|------|------|
| 搜不到这本书的任何内容 | `folder` 写错 / 书未入库 / `--include-pdfs` 缺失 | 先 `book_admin.sh status`，再核对回执的 `search_folder` |
| 检索返回的是笔记而不是原文 | `folder` 漏传或指向了 `notes/` | 改回 `search_folder` |
| 写作工具 not found | 服务端缺 `--enable-write` | 告知用户重启 enquire-mcp 带该参数，**不要绕过它去用 shell 写 vault** |
| `extract_failed`，扫描版 | PDF 无文本层 | `BOOK_OCR=true` + 服务端 `install-ocr-lang <code>`，或改用 `obsidian_read_pdf` + `obsidian_ocr_pdf` 逐页 |
| `extract_failed`，MOBI | 缺转换器 | 装 calibre（`brew install calibre`）或先转 EPUB |
| EPUB 章节顺序错乱 | OPF spine 损坏 | 退回按归档顺序；提示用户该书 spine 不规范 |
| `config_not_found` | 没有任何层提供 `VAULT_DIR` | 转述 `searched` 数组，引导用户跑 `--init`。**不要自己写配置文件** |
| 中文文件名导入报 `slug_undetermined` | slug 化只保留 ASCII | 显式传 `--slug <拼音或英文名>` |

---

## 六、绝对禁止

- ❌ 把整章、整节、整本书的正文读进上下文 —— 违反本 skill 存在的唯一理由
- ❌ 漏掉 `folder` 参数 —— 会检索到自己写的笔记，制造伪引用
- ❌ 伪造或推断 `[page: N]` —— 页码只能来自 `obsidian_search` / `obsidian_read_pdf` 的原始返回
- ❌ 在 LLM 调用里跑 `--init` / `--detect` / `enquire-mcp setup` / `build-embeddings`
- ❌ 自己读、打印或改写 `.mario-skills/.env` —— 那是人负责的共享凭据文件；用 `--config-info` 查
- ❌ 用 shell 工具绕过 MCP 去写 vault 里的笔记 —— 会绕过 enquire 的 watcher 一致性
- ❌ 把 EPUB/TXT 原文塞进 `notes/` —— 原文只放 `_source/`
- ❌ 把 digest 笔记和原文放同一个目录 —— 隔离是本 skill 正确性的前提
- ❌ 未经确认就传 `overwrite=true`
- ❌ Phase 0 模式下询问"要不要入库" —— 识别为附件即跑，不问、不等、不引导
- ❌ Phase 0 多文件全跑（> `BOOK_AUTO_INGEST_MAX`） —— 批量拖入会让 token 雪崩
- ❌ Phase 0 跳过 0.2 直接写 chapter notes —— 没拿到 `search_folder` 就抓不到原文切片
- ❌ Phase 0 处理非 6 格式的文件（html/azw3/markdown 等）—— 白名单硬约束，terminate silently
- ❌ Phase 0 把 vault 内其它路径（如 `wiki/`, `assets/`, `10-Claude/`, `journals/`）的文件当书处理 —— 那是其它 skill 的领地，§0.1 预检应当直接拒绝
- ❌ 直接调 `book_import.sh --book /tmp/...` 绕过 scope 检查 —— 脚本会返回 `scope_error`；调用前必须先 cp 进 `<VAULT_DIR>/<BOOKS_SUBDIR>`（Phase 0 §0.1 的职责）
- ❌ 改 `BOOKS_SUBDIR` 的默认值到 `books` —— 0.5.0 起默认 `raw/books`，改了等于和 vault 的实际布局脱节
- ❌ Phase 0 给 `skip_unchanged` 调 MCP —— 直接回执"已在库"，省 MCP 调用