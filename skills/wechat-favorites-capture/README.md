# wechat-favorites-capture

[English](./README.en.md) | 中文

把本机微信收藏变成 Obsidian vault 里能检索、能引用的素材。收藏库解密导出 → 按主题分桶分层 → 收藏文章的正文抓成 Markdown → 一份单文件 HTML 报告。**只搬运，不加工。**

## Why this exists

微信收藏是个人知识库里最被低估的一块：几年下来几百条「当时觉得有用」的文章躺在一个加密的 SQLite 文件里，既搜不了也用不上。

搬它难在三个地方：

1. **库是加密的。** `favorite.db` 是 SQLCipher 4，密钥只在微信进程内存里，磁盘上找不到。
2. **微信文章页有 `poc_token` 校验。** 直接发 HTTP 请求只会拿到一个「环境异常」验证页，必须用真实浏览器渲染。
3. **几百条收藏不能全抓。** 全抓要几小时，而且大部分是三年前的旧技术细节，对当下的写作没有价值。

这个 skill 做四件事：

1. **解密** —— frida hook 微信的 PBKDF2 派生，拿到密钥后逐页校验 HMAC 再解密
2. **分层** —— 主题分类 + 时间分层，把「值得抓的几十篇」从「几百条收藏」里挑出来
3. **抓正文** —— 驱动真实浏览器，HTML→Markdown 在页面内完成，正文不进模型上下文
4. **可复现** —— 关键词词表在 `data/taxonomy.json`，改词表就能改分桶结果

## 架构

```
  微信 Mac（已登录，已收藏过东西）
        │
        │  ① 密钥提取：frida hook CCKeyDerivationPBKDF
        │     跑之前要关掉正在运行的微信；需要一份 ad-hoc 重签名的副本
        ▼
  ┌────────────────────────────────────────────────┐
  │  wfc_capture.sh                                 │
  │  ├─ wfc_env.sh        共享 .mario-skills/.env   │
  │  ├─ decrypt_favorite_db.py   SQLCipher 4 逐页解密 │
  │  ├─ wfc_classify.py   主题分类 + 分层 + URL 清单  │
  │  ├─ wfc_preflight.sh  浏览器环境自检 + 自愈      │
  │  └─ wfc_setup.sh      首次向导（人跑）           │
  └────────────────────────────────────────────────┘
        │                          │
        │ ② export                │ ③ scrape（分块 ≤6，间隔 20s）
        ▼                          ▼
  <dataset>/favorites.json    <dataset>/articles/<分类>/{日期}-{标题}.md
  <dataset>/classified.json   <dataset>/urls/<分类>.txt
  <dataset>/report.html
```

**为什么分块 ≤6 篇**：opencli 的浏览器会话连抓十几篇后会整体僵死——不是 URL 的问题，也不是标签页堆积（`tab list` 始终只有 1 个）。分块 + 间隔 20 秒 + 只重试失败的那几篇，是实测下来唯一稳定的组合。

**为什么正文不进上下文**：一篇原始 HTML 几十到几百 KB。转换在浏览器页面内做完直接落盘，抓 1 篇和抓 100 篇的 token 开销应该是一样的。

## Quickstart

### 1. 依赖

```bash
npm install -g opencli        # 浏览器桥
opencli doctor                 # 必须全绿，尤其 "Extension: connected"
```

还需要：

- **Chrome**（微信文章页必须真实浏览器渲染）
- **`wechat-article-scraper` skill**（正文抓取）—— 装在 `~/.claude/skills/wechat-article-scraper`
- **`wx-favorites-report` skill**（解析 + HTML 报告）—— 向导会自动 clone

### 2. 配置（一次，人工）

```bash
bash scripts/wfc_setup.sh --detect        # 看本机 vault、收藏库、依赖状态
bash scripts/wfc_setup.sh --init --dry-run  # 预演
bash scripts/wfc_setup.sh --init            # 确认写入
```

向导会问「采集内容保存到 vault 的哪个目录」，默认 `raw`；并把解密用的 venv（frida + pycryptodome）装好。

如果 `~/.mario-skills/.env` 里已经有 `VAULT_DIR`（`diary-writer` 或 `book-enquire-reader` 写下的），向导不会覆盖它。

### 3. 跑

```bash
bash scripts/wfc_capture.sh capture --tier T1 --limit 50   # 一条命令跑完整条流程
```

`capture` 会自动判断要不要解密（`favorites.json` 在就跳过）、跑分类、抓正文、出报告，
并在抓之前把浏览器环境修好（daemon、profile、死标签页租约），最后只吐一行 JSON 回执。

要单独跑某一步时：

```bash
bash scripts/wfc_doctor.sh --json                       # 体检
bash scripts/wfc_capture.sh export                     # 解密 → favorites.json
bash scripts/wfc_capture.sh classify                   # 分类 → classified.json + urls/
bash scripts/wfc_capture.sh scrape                     # 抓正文 → articles/
bash scripts/wfc_capture.sh report                     # HTML 报告
```

`export` 需要密钥。回执会返回 `error: "key_required"` 和该跑的命令——细节见 `references/decrypt-and-export.md`。

## 配置

全部走共享的 `.mario-skills/.env`（marketplace 统一约定）：

| 键 | 默认 | 说明 |
|----|------|------|
| `VAULT_DIR` | — | vault 根。**与 `diary-writer`、`book-enquire-reader`、`dedao-course-sync` 共用同一个键** |
| `WX_FAV_OUT_SUBDIR` | `raw` | 采集保存目录，相对 vault。也可以写绝对路径 |
| `WX_FAV_SET_SUBDIR` | `WeChat-Favorites` | 数据集子目录。留空 = 直接存在上面那个目录里 |
| `WX_FAV_TIER` | `T1` | 默认抓取分层：`T1` / `T2` / `T3` / `all` |
| `WX_FAV_LIMIT` | `0` | 默认最多抓几篇。`0` = 不限 |
| `WX_FAV_CHUNK` | `6` | 每块几篇。浏览器会话的上限，别调大 |
| `WX_FAV_DELAY` | `20` | 每篇间隔秒数。微信风控，15~20 比较安全 |
| `WX_FAV_TAG` | `wechat-favorites` | 写进 frontmatter 的 tag |
| `WX_FAV_SESSION` | `wxscrape` | opencli 浏览器会话名。preflight 自检和正文抓取用同一个 |
| `WX_FAV_STATE_DIR` | `~/.local/share/wechat-favorites-capture` | 解密工作副本、密钥日志、venv。不在 vault、不在 skill 目录 |
| `WX_FAV_DB` | 自动探测 | 微信收藏库路径 |
| `WX_FAV_VIZ_SKILL` | 自动探测 | `wx-favorites-report` skill 位置 |
| `WX_FAV_SCRAPER_SKILL` | 自动探测 | `wechat-article-scraper` skill 位置 |
| `OPENCLI_BIN` | `opencli` | 浏览器桥可执行文件。**与 `dedao-course-sync` 共用同一个键** |

解析优先级：`process.env` → `<项目>/.mario-skills/.env` → `~/.mario-skills/.env` → 内置默认值。逐 key 独立解析，未知键忽略。

查来源：`bash scripts/wfc_capture.sh config-info`（加 `--json` 机读）。

完整模板见 [`examples/env.shared.example`](./examples/env.shared.example)。

## 命令

```bash
# 体检（agent 可跑）
bash scripts/wfc_doctor.sh --json

# 流水线
bash scripts/wfc_capture.sh export [--keylog P | --key HEX]
bash scripts/wfc_capture.sh classify [--tier T1|T2|T3|all] [--limit N]
bash scripts/wfc_capture.sh scrape [--category C] [--tier T] [--limit N] [--dry-run]
bash scripts/wfc_capture.sh report
bash scripts/wfc_capture.sh all [scrape 的参数...]
bash scripts/wfc_capture.sh capture [--tier T] [--limit N] [--category C] [--dry-run] [--no-report]
                                      # 整条流程一条命令；已导出过就跳过 export

# 浏览器环境自检 + 自愈（capture 内部自动调用，也可单独跑）
bash scripts/wfc_preflight.sh --session wxscrape

# 配置（人跑，不要从 LLM 调用里执行）
bash scripts/wfc_setup.sh --init [--dry-run]
bash scripts/wfc_setup.sh --detect
```

### 输出约定

**stdout 只有 JSON 回执，人读信息全在 stderr。** 调用方可以直接 `json.loads(stdout)`。

`all` 的回执是四步的**汇总**（export / classify / scrape / report 各一段，带收藏总数、
类目数、层级分布、抓取成功失败篇数），不是只重复最后一步。

| 退出码 | 含义 |
|--------|------|
| 0 | 成功 |
| 1 | 这一步失败了（看回执里的 `error`） |
| 2 | 配置缺失、vault 不存在、参数错误 |

`--init` / `--detect` 是给人跑的命令，不要从 LLM 调用里执行。

**层级在哪一步筛。** `classify` 把所有层的 URL 都写进 `urls/<分类>.txt`，并在 `urls/_index.json` 里记下每个 URL 属于哪一层；`scrape --tier T2` 是逐条从索引里挑出 T2 的那些。所以分类跑一次就够，换层不用重新分类。默认 `scrape` 取配置的 `WX_FAV_TIER`（默认 `T1`）。

**`--limit N` 是总量预算**，不是每个类目各 N 篇。跨类目按**类目大小降序**分配（最大的类目先花预算），
`--limit 0`（默认）表示不限。要专门抓某一类，配 `--category`。

## 为什么是脚本而不是 agent 驱动

第一版把这套流程交给 agent 一步步驱动，跑一次实测烧掉 **10 万 token 以上**——不是因为任务
本身复杂，而是因为 agent 在做三件本该由脚本做的事：

1. **读脚本源码**（`sed -n 1,80p scrape.py`、`grep canon_url`）来搞清楚参数怎么传
2. **跑 `opencli --help` / `opencli weixin --help`** 来搞清楚浏览器桥的命令
3. **逐条排查同一个机械性故障**——daemon 没起、profile 没选、上一轮留下的死标签页租约，
   三个症状都表现为「浏览器打开失败」，每次都要重新推理一遍

现在这些都在 `scripts/` 里：`wfc_preflight.sh` 自检并自愈浏览器环境，`capture` 把四步串成
一条命令，agent 只读一行 JSON 回执。**故障从「需要推理」变成了「需要重跑」。**

## 已知边界

**只能在 macOS 上解密。** 密钥提取靠 frida attach 微信进程，微信没有 iOS 以外的桌面版 Linux/Windows 包。

**密钥提取不是全自动的。** 需要关掉正在运行的微信、准备一份重签名副本、在 300 秒窗口内登录。这几步没法脚本化——脚本没法替你登录。

**微信升级后密钥会变。** 症状是解密时 HMAC 校验失败，重跑一次提取流程即可。

**部分收藏永远抓不到正文。** 原文被删除、因违规下架、作者开了隐私设置——重试一万次也一样。元数据（标题、来源、收藏时间）还在，只是正文拿不到。

**`IMG` 层（`image_detail` 图片消息页）基本无效。** 收藏里这类条目多数已失效，不投抓取资源。

**分类词表是起点不是终点。** `data/taxonomy.json` 里的词表是按一套技术 + 自媒体的语料调的。换一批收藏就得改词表，或者直接换成自己的分类体系。

**图片不下载。** 正文图片保留 `mmbiz.qpic.cn` 的 CDN 地址。vault 里装了 `obsidian-local-images-plus` 的话要排除采集目录，否则它会把图片拉到 `assets/` 并改写链接——细节见 `references/scraping.md`。

**收藏内容是敏感素材。** 标题、来源、摘要记录的是一个人的浏览偏好。只在本机处理，不要公开分享。

## License

MIT — 见 [LICENSE](./LICENSE)。
