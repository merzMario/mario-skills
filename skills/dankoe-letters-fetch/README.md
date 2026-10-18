# dankoe-letters-fetch

[English](./README.en.md) | 中文

把 [Dan Koe 的 newsletter](https://letters.thedankoe.com) 增量抓进 Obsidian vault 的 `raw/DanKoe/原文/`。**只抓不加工。**

## Why this exists

Dan Koe 每周更新 free/proof newsletter，值得归档进库做素材和观点来源。但 Substack 的 archive API 有四个不直观的约束，踩错任意一个都会**静默少抓或抓错** —— 症状都不像报错：

1. `limit` 上限 23，填 24/30 被**静默钳回** 23 条（不报错），填 100 才报 `Invalid value`。必须 offset 步进 23 逐页拉
2. archive **列表**里的 `body_html` 恒为 `null` —— 正文只在单篇端点 `/api/v1/posts/<slug>`
3. 付费墙不能用正文关键词判定 —— 被截断的正文可能完全不含文案，直接断在词中间
4. Substack 给重发文章加消歧后缀（`-ef8`），那是**不同文章**，去重必须 slug 精确匹配

第 1 条和第 3 条最危险：都不报错，只是结果不对。把这套知识写成 prompt 等于每次重新踩一遍，所以它在这里是**代码**。

## 架构

```
  letters.thedankoe.com
          │
          │ ① 枚举（纯 curl，零浏览器）
          │   GET /api/v1/archive?sort=new&limit=23&offset=N
          │   每页恰好 23 —— 更大的 limit 会被静默钳回
          │   每条带 audience 字段：everyone=免费 / only_paid=付费墙
          ▼
      ┌────────────────────────────┐
      │  dankoe_fetch.sh           │  bash 入口：解析 .mario-skills/.env
      │  └─ dankoe_fetch.py        │  Python 内核：枚举 / 去重 / 抓正文 / 清洗
      └────────────────────────────┘
          │
          │ ② 去重：扫原文/ 下文件名提 slug，**精确**匹配
          │ ③ 正文：opencli browser extract --selector article
          │    兜底：单篇 API 的 body_html（浏览器两次失败时）
          ▼
  $VAULT_DIR/raw/DanKoe/原文/20260919-the-one-human-business-原文.md
  $VAULT_DIR/raw/DanKoe/翻译/20260919-the-one-human-business-翻译.md   ← 另一条流程
```

**为什么去重要 slug 精确匹配**：前缀匹配会把 `-ef8` 消歧版误判成已抓，而那是不同的文章。

## Quickstart

### 1. 依赖

```bash
# list 只需要 curl
curl --version

# fetch 需要浏览器桥
npm install -g opencli
opencli doctor              # 必须全绿，尤其 "Extension: connected"
```

Substack 是公开的，**不需要登录**。但正文要等 JS 渐进渲染，所以仍需浏览器 + OpenCLI 扩展。

### 2. 配置（一次，人工）

```bash
bash scripts/dankoe_fetch.sh --detect
bash scripts/dankoe_fetch.sh --init
```

如果 `~/.mario-skills/.env` 里已经有 `VAULT_DIR`（其他 mario skill 写下的），本 skill 直接能用。

### 3. 抓

```bash
bash scripts/dankoe_fetch.sh list  --count 10    # 只看有什么新的
bash scripts/dankoe_fetch.sh fetch --count 10    # 抓
```

## 配置

走共享的 `.mario-skills/.env`：

| 键 | 默认 | 说明 |
|----|------|------|
| `VAULT_DIR` | — | vault 根。**与 `diary-writer`、`book-enquire-reader`、`dedao-course-sync` 共用** |
| `DANKOE_OUT_SUBDIR` | `raw/DanKoe` | 产出根，文章落在其下的 `原文/` |
| `DANKOE_SESSION` | `dankoe-letters` | opencli 会话名。别和别的进程共用 |
| `DANKOE_COUNT` | `10` | 默认批量 |
| `DANKOE_STATE_DIR` | `~/.local/share/dankoe-letters-fetch` | 失败清单 |
| `OPENCLI_BIN` | `opencli` | 浏览器桥 |

解析优先级：`process.env` → `<项目>/.mario-skills/.env` → `~/.mario-skills/.env` → 内置默认值。

查来源：`bash scripts/dankoe_fetch.sh --config-info`（`--json` 机读）。

> ⚠️ 历史上这个 skill 的路径写的是 `00-Raw/DanKoe/原文/`。你 2026-10-12 重组目录时（`00-Raw/` → `raw/`）实际产出去了 `raw/`，但 skill 没跟着改 —— **去重因此完全失效**，每次重跑都会把全部文章重抓一遍。现在指向 `raw/DanKoe/`。

## 命令

```bash
bash scripts/dankoe_fetch.sh list  [--count 10]
bash scripts/dankoe_fetch.sh fetch [--count 10] [--dry-run]

bash scripts/dankoe_fetch.sh --init [--project] [--dry-run]
bash scripts/dankoe_fetch.sh --detect
bash scripts/dankoe_fetch.sh --config-info [--json]
```

`--init` / `--detect` 是给人跑的命令，不要从 LLM 调用里执行。

### 输出约定

**stdout 只有 JSON 回执，人读信息全在 stderr。**

| 退出码 | 含义 |
|--------|------|
| 0 | 成功（含「没有新内容」） |
| 1 | **有任何一篇抓取失败** |
| 2 | 配置缺失、vault 不存在、参数错误、缺 opencli（仅 `fetch`） |

失败清单写在 `$DANKOE_STATE_DIR/dankoe-fetch-errors.json`，全部成功后自动删除。

## 落盘格式

`原文/YYYYMMDD-{slug}-原文.md`：

```markdown
# {English Title}

### {Subtitle}

**Source**: https://letters.thedankoe.com/p/{slug}
**Published**: {YYYY-MM-DD}
**Author**: Dan Koe

---

{正文}
```

用**粗体键值行，不是 YAML frontmatter** —— 这是 `raw/DanKoe/` 的既有惯例（`翻译/` 下 95 篇也是这个格式），换了会让下游解析失效。

日期一律取 archive 的 ISO 日期。**不要用页面显示日期**（`Sep 20, 2026` 是本地时区渲染，会差一天）。

## 已知边界

**渲染等待是必须的。** Substack 渐进渲染，extract 跑太早会拿到 `selector_not_found`（好认）或**半截正文**（断在词中间，像付费墙截断，实为假阳性）。所以流程是 open → wait selector → 等 2.5s → extract，尾部缺收尾特征再重抽一次。

**完整性判据是尾部特征，不是字数。** 正文 ≥ 1000 字符**且**尾部有 `Likes` / `Restacks` / `– Dan` 才落盘。单看字数会漏掉「抓了大半」的情况。

**archive 里可能有已删除的文章。** 2026-10-18 实测：vault 有 95 篇，archive 只列 91 篇，其中 5 篇在 archive 和单篇端点都返回 `Post not found`（上游已删）。所以 **`exhausted: true` 指的是「archive 已追平」，不是「vault 和 archive 一致」**。

**图片不下载。** 保留 CDN URL 引用。

**翻译是另一条流程。** `翻译/` 目录由独立的翻译流程维护，本 skill 不碰。

## License

MIT — 见 [LICENSE](./LICENSE)。
