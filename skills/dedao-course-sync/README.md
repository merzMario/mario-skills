# dedao-course-sync

[English](./README.en.md) | 中文

得到 APP 两个付费专栏（得到精选 / 得到头条）的增量同步。内容抓进 Obsidian vault 的 `raw/Courses-GetIt/`，**只抓不加工**。

## Why this exists

得到是两个付费专栏，日更。手工收藏的路径必然崩：漏、断、重复、格式不一。

这个 skill 做三件事：

1. **增量** —— 按得到侧的文章 ID（`article_id`）去重，已抓的永不重抓
2. **可核验** —— 每篇带 frontmatter（`article_id` / `source` / `published`），能溯源回得到
3. **干净** —— 正文只取 `.article-body`，剥掉页面元素，标题改名也不影响去重

## 架构

```
  Chrome（已登录得到）+ OpenCLI 扩展
                │
                │  ① 列表：页面内 fetch JSON 接口
                │     POST /pc/bauhinia/pc/class/purchase/article_list
                │     reverse=true 倒序 · count≤50 · max_id 游标翻页
                ▼
      ┌───────────────────────────┐
      │  dedao_sync.sh            │  bash 入口：解析 .mario-skills/.env
      │  └─ dedao_sync.py         │  Python 内核：翻页 / 去重 / 抓正文 / 清洗
      └───────────────────────────┘
                │
                │  ② 去重：扫 frontmatter 的 article_id（不是文件名）
                │  ③ 正文：opencli browser extract --selector .article-body
                ▼
  $VAULT_DIR/raw/Courses-GetIt/得到精选/2026-10-17-为什么越追求平等越不平等.md
  $VAULT_DIR/raw/Courses-GetIt/得到头条/…
```

**为什么去重按 `article_id` 而不是文件名**：标题会改，slug 清洗规则也变过（见 `SKILL.md` 第四节）。按文件名比对必然把改过标题的文章当成新的重抓一遍。

## Quickstart

### 1. 依赖

```bash
npm install -g opencli          # 浏览器桥
opencli doctor                   # 必须全绿，尤其 "Extension: connected"
```

Chrome 需要**已登录得到**，且装了 [OpenCLI 扩展](https://chromewebstore.google.com/detail/opencli/ildkmabpimmkaediidaifkhjpohdnifk)。脚本没有账号密码，登录只能由人在浏览器里完成。

### 2. 配置（一次，人工）

```bash
bash scripts/dedao_sync.sh --detect    # 看本机 vault 和 opencli 状态
bash scripts/dedao_sync.sh --init      # 写 ~/.mario-skills/.env
```

如果 `~/.mario-skills/.env` 里已经有 `VAULT_DIR`（`diary-writer` 或 `book-enquire-reader` 写下的），本 skill 直接就能用，不必再配。

### 3. 抓

```bash
bash scripts/dedao_sync.sh fetch --course all --count 20
```

单篇约 4~6 秒，20 篇 × 2 个专栏大约 4 分钟。

## 配置

全部走共享的 `.mario-skills/.env`（marketplace 统一约定）：

| 键 | 默认 | 说明 |
|----|------|------|
| `VAULT_DIR` | — | vault 根。**与 `diary-writer`、`book-enquire-reader` 共用同一个键** |
| `DEDAO_OUT_SUBDIR` | `raw/Courses-GetIt` | 产出目录，相对 vault |
| `DEDAO_SESSION` | `dedao-sync` | opencli 浏览器会话名。并发跑会互相换标签页，别让两个进程用同一个 |
| `DEDAO_COUNT` | `20` | 默认批量，`--count` 不给时用它 |
| `DEDAO_STATE_DIR` | `~/.local/share/dedao-course-sync` | 失败清单。不在 vault、不在 skill 目录 |
| `OPENCLI_BIN` | `opencli` | 浏览器桥可执行文件 |

解析优先级：`process.env` → `<项目>/.mario-skills/.env` → `~/.mario-skills/.env` → 内置默认值。逐 key 独立解析，未知键忽略。

查来源：`bash scripts/dedao_sync.sh --config-info`（`--json` 机读）。

**课程 ID、slug 清洗表、正文锚点刻意不可配。** 三者是成对的：只换课程 ID 会让 slug 规则和 `body_anchor` 对不上，产出格式错误但看起来正常的文件。要加新专栏得同时补这三样。

## 命令

```bash
# 抓
bash scripts/dedao_sync.sh fetch --course all [--count 20] [--dry-run]

# 只看有什么新的
bash scripts/dedao_sync.sh list --course all

# 配置
bash scripts/dedao_sync.sh --init [--project] [--dry-run]
bash scripts/dedao_sync.sh --detect
bash scripts/dedao_sync.sh --config-info [--json]
```

`--init` / `--detect` 是给人跑的命令，不要从 LLM 调用里执行。

### 输出约定

**stdout 只有 JSON 回执，人读信息全在 stderr。** 调用方可以直接 `json.loads(stdout)`，不必解析人话。

| 退出码 | 含义 |
|--------|------|
| 0 | 成功（含「没有新内容」） |
| 1 | **有任何一篇抓取失败** —— 部分失败不会被吞掉，cron/launchd 能感知 |
| 2 | 配置缺失、vault 不存在、参数错误、opencli 不在 PATH |

失败清单写在 `$DEDAO_STATE_DIR/dedao-sync-errors.json`。某轮全部成功后旧清单自动删除。

## 已知边界

**必须有 Chrome 登录态。** 得到是付费内容，脚本没有账号密码。这是硬约束，没有任何绕过方式。

**得到改版就会失灵。** 脚本硬编码了 `.article-body` 选择器和开场白锚点（`你好` / `这里是《` / `各位`）。得到改版后症状是「等了 45s 仍不合格」或「清洗后只剩 N 字」，此时需要改选择器或锚点。README 里 `raw/Courses-GetIt/README.md` 记着完整的排错流程。

**只覆盖两个专栏。** 得到精选和得到头条。同目录另外 4 个课程是已完结课程，由更早的流程一次性抓完，本 skill 不碰。

**`--dry-run` 仍需浏览器。** 待抓清单来自那个 JSON 接口，不调就没有清单可列。它保证的是「不写任何文件」。

**图片不在职责内。** 正文保留远程链接，Obsidian 的 `obsidian-local-images-plus` 插件负责下载和改写。

**串行跑，别并发。** 同一个 `DEDAO_SESSION` 下两个进程会互相把标签页换掉，正文探针会读到上一篇。

## License

MIT — 见 [LICENSE](./LICENSE)。
