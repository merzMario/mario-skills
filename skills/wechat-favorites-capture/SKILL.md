---
name: wechat-favorites-capture
description: 把微信 Mac 客户端的收藏库（SQLCipher 加密的 favorite.db）解密导出、按主题分桶分层、再把收藏文章的正文抓成 Markdown 存进 Obsidian vault。当用户说「抓取微信收藏」「把微信收藏存进 Obsidian」「微信收藏导出」「收藏夹入库」「收藏文章抓正文」「收藏可视化报告」，或提到想把微信收藏 / 收藏过的公众号文章搬进 Vault、导入笔记、存到 raw 时使用 —— 哪怕用户没说「收藏」两个字，只要素材来源是本机微信收藏，就该用它。也用于查看收藏夹里都有什么、给收藏按主题和价值分层、给收藏生成单文件 HTML 报告。
---

# 微信收藏 → Obsidian

把本机微信收藏变成 vault 里能检索、能引用的素材。整条流水线是四步，每一步都由脚本干完，你只负责选参数和转述结果。

```
favorite.db (加密) ──export──> favorites.json ──classify──> classified.json + urls/*.txt
                                                                      │
                                                    scrape ──────────┘
                                                                      ▼
                                              <dataset>/articles/<分类>/*.md

                              favorites.json ──report──> report.html
```

## 它做什么，不做什么

**做：** 解密收藏库 → 导出结构化 JSON → 按主题和价值分层 → 把文章的正文抓成 Markdown → 出一份 HTML 报告。

**不做：** 不碰微信账号本身，不抓取收藏以外的任何内容，不改写 vault 里已有的文件，不下载图片。

素材落点是用户配置的保存目录（默认 vault 的 `raw/`）。`raw/` 在这个 vault 里是**只读原始素材区**——这个 skill 只往自己那一个子目录里写，不动同级任何文件。

## 第一次用：配置由人来定

配置写在共享的 `~/.mario-skills/.env`，键名前缀 `WX_FAV_`。**这一步必须由用户本人执行**，你不能代跑——向导会从 `/dev/tty` 读回答并写用户的配置文件，用户说「收藏抓哪儿」时应该由他们自己选。

告诉用户运行：

```bash
bash <skill-dir>/scripts/wfc_setup.sh --init --dry-run   # 先预演
bash <skill-dir>/scripts/wfc_setup.sh --init             # 确认写入
```

向导会问「采集内容保存到 vault 的哪个目录」，默认 `raw`，并把依赖装齐（解密用的 venv、wx-favorites-report skill）。装不上的依赖（opencli、浏览器扩展）只会报告，不会硬装。

用户跑完之后，你再跑 `doctor` 确认。

## 日常调用

**默认走 `capture` 一条命令。** 它把「检查是否已导出 → 分类 → 抓取 → 报告」串起来，
浏览器环境的自检和修复也在里面，最后只吐一行 JSON 回执。

```bash
bash <skill-dir>/scripts/wfc_capture.sh capture --tier T1 --limit 50
```

**不要自己驱动那四步，也不要自己诊断 opencli。** 那两件事过去要靠 agent 读脚本源码、
跑 `opencli --help`、翻 `.crawl.log` 逐条推理——一次下来十几万 token，而且大部分时间
花在重复排查同一批机械性故障上（daemon 没起、profile 没选、上一轮留下的死标签页租约）。
`capture` 已经在抓之前把这些修好了。

要单独跑某一步时才用这些：

```bash
bash <skill-dir>/scripts/wfc_capture.sh export      # 解密 → favorites.json
bash <skill-dir>/scripts/wfc_capture.sh classify    # 分类 → classified.json + urls/
bash <skill-dir>/scripts/wfc_capture.sh scrape      # 抓正文 → articles/<分类>/
bash <skill-dir>/scripts/wfc_capture.sh report      # 单文件 HTML 报告
bash <skill-dir>/scripts/wfc_capture.sh doctor      # 依赖体检
python3 <skill-dir>/scripts/wfc_readme.py            # 重写采集目录的 README（篇数表 + 缺口台账）
```

所有命令都往 stdout 打一行 JSON 回执，人看的进度走 stderr。**每一步都要看回执**——
回执里的 `ok:false` 和 `error` 字段是判断下一步的唯一依据。

体检里 `required: true` 的项缺了就别往下走；`required: false` 的项只影响某一步（比如解密
用的 venv 只卡 `export`），不挡 `classify` / `scrape`。

**已经导出过就跳过 `export`。** 它是最贵的一步（要密钥、要用户退出微信），而
`favorites.json` 已经在采集目录里的时候，`classify` 可以直接跑。`capture` 会自动判断。

常用开关：`--tier T1|T2|T3|all`（抓哪一层，默认 `T1`）、`--limit N`（最多几篇）、
`--category <类目>`（只抓某一类）、`--dry-run`（只列不抓）、`--no-report`（跳过报告）。

**`--limit N` 是总量预算**，不是每个类目各 N 篇。用户说「抓 3 篇」就拿到 3 篇，
跨类目按**类目大小降序**分配（最大的类目先花预算）。要专门抓某一类，配 `--category`。

**层级是抓的时候才筛的。** `classify` 会把所有层的 URL 都写进清单，并在 `urls/_index.json` 里记下每个 URL 属于哪一层；`scrape --tier T2` 是逐条过滤出来的 T2，不是「重新导一份 T2 的清单」。所以只要分类跑过一次，换层不用重跑。

要临时换个 vault 或保存位置，用进程环境覆盖，不用改配置：

```bash
VAULT_DIR=/tmp/somewhere bash <skill-dir>/scripts/wfc_capture.sh capture --dry-run
```

`export` 需要解密密钥。微信的收藏库是 SQLCipher 加密的，密钥只能在微信运行时从内存里捞——所以这一步没法全自动。回执会返回 `error: "key_required"` 和该跑的命令：

```bash
<venv>/bin/python <skill-dir>/scripts/extract_key.py \
  --app ~/Desktop/WeChat.app --seconds 300 --log <state>/wechat_frida_keys.log
```

**这一步交给用户跑，别自己执行。** 它要**关掉正在运行的微信**（数据目录跟登录身份走，attach 不上正在跑的实例），还要一份 ad-hoc 重签名的微信副本。这是在动用户机器上的应用，不是一个能顺手代劳的命令。把命令和前置条件告诉用户，让他们自己决定什么时候做。

完整步骤在 `references/decrypt-and-export.md`，**在给用户转述之前读它**——里面写清了签名为什么必须用 `ditto` 而不是 `cp -R`（`cp -R` 会丢掉代码签名元数据，重签之后微信启动即退），以及为什么密钥日志用完要立刻删掉。

拿到密钥后再跑一次 `export --keylog <path>`。

## 分层是什么意思

分类器把每条收藏归到一个主题桶，再打一个层级标签：

| 层 | 含义 | 默认抓吗 |
|---|---|---|
| T1 | 2024 年起的 AI 时代内容 | ✅ 默认 |
| T2 | 2024 年前，但还值得留着的（管理、理财、生活） | 看你需要 |
| T3 | 旧技术细节，现在读意义不大 | ❌ |
| IMG | `image_detail` 图片消息页，多半已失效 | ❌ |
| NOLINK | 图片收藏、聊天文件等，没有可抓的链接 | ❌ |

分层规则和主题词表都在 `data/taxonomy.json`，改那个文件就能改分桶结果，不用碰 Python。判定逻辑（强词优先、弱词兜底、同来源继承、人工判定表）在 `references/scraping.md` 的分类小节里——**只在你需要改分桶时才读**。

## 抓取会遇到的坑

这一段是实测出来的，不是猜的，值得先知道：

**抓之前环境已经修好了。** `capture`（和 `scrape`）在开抓之前会跑一遍
`scripts/wfc_preflight.sh`：daemon 没起就起、没选 profile 就选一个、上一轮留下的死标签页
租约就释放掉，并验证浏览器确实能渲染页面。这三样过去都表现为「浏览器打开失败」，是 agent
每次都要重新推理一遍的机械性故障——现在不需要推理了。**如果你看到「浏览器打开失败」，
先跑 `bash <skill-dir>/scripts/wfc_preflight.sh` 看它修了什么**，而不是自己去翻
`opencli --help`。

**浏览器会话会僵死。** 连抓十几篇之后 opencli 的浏览器会话会整体卡住——不是 URL 的问题，也不是标签页堆积（`tab list` 始终只有 1 个）。默认已经按 ≤6 篇分块、每篇间隔 20 秒、跑在前台。遇到连续失败**只重试失败的那几篇**，别整批重来：成功的那些已经在 `.index.json` 里，重抓会撞上重名逻辑。

**失败的条目多半永远不会成功。** 原文被发布者删除、因违规下架、或作者开了隐私设置——重试一万次也一样。`scrape` 会把每篇失败的重试**一次**（会话僵死是可以重试的，失效的条目不是），再不行回执里的 `failed_items` 就是这些。汇报时如实说是失效，不是「抓取失败」，更不要尝试绕过。

**失败清单是跨轮次累积的。** `scrape` 把失败的条目写进 `urls/_failed.json`，重试成功的自动移除。所以这个文件里的每一条都是**真的试过**的。`wfc_readme.py` 靠它把「抓不到」（原文没了）和「还没抓」（分层规则拦下的旧内容）分开——没有它，缺口台账会把两百条没抓过的和五条已失效的混成同一句话。

**不是微信文章链接的收藏不进待抓清单。** 收藏夹里混着抖音视频页、头条、51CTO 这类
链接，正文抓取器只处理 `mp.weixin.qq.com`——让它们进清单只会让每条空转三次重试、白等
两分钟。它们被单独记在 `urls/_skipped.json`，回执里的 `skipped_not_wechat` 是它们的数量。
这不是失败，是本来就抓不了。

**图片保持 CDN URL。** 抓下来的 Markdown 里图片是 `mmbiz.qpic.cn` 的原始地址，不下载。这是刻意的：正文图片体积远大于文字，下载既慢又把 vault 撑大。如果你的 vault 装了 `obsidian-local-images-plus` 之类的插件，它会把外链图片下载到 `assets/` 并改写链接——需要在插件设置里排除这个采集目录（细节见 `references/scraping.md`）。

**不要把抓下来的正文读进上下文。** 一篇正文的原始 HTML 有几十到几百 KB。一篇和一百篇的 token 开销应该是一样的：脚本落盘，你只报数字（成功几篇、失败几篇、输出目录）。

## 出口码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 这一步失败了（看回执里的 `error`） |
| 2 | 配置缺失，或参数不对 |

## 硬性禁止

- **不代跑 `--init`。** 用户的钱包、用户的选择。你可以做的是把命令给他，把他的回答写成配置——由他自己跑。
- **不把收藏内容发到 vault 以外的地方。** 收藏标题、来源、摘要记录的是一个人的浏览偏好，属于敏感素材。只在本机处理。
- **不改 `raw/` 里已有的文件。** 这个 skill 只往自己配置的采集目录写新文件。发现已有文件有问题，在 wiki 笔记里标注，不要动原始素材。
- **不为了抓一篇去绕过平台的访问控制。** 抓不到就是抓不到，如实报失败。
- **不把解密出来的库、密钥日志、frida 进程留在磁盘上。** 用完删掉 `/tmp` 里的密钥日志和桌面上重签名过的微信副本。

## 参考文件

- `references/decrypt-and-export.md` —— 签名、副本、密钥提取、解密、跨库校验。**跑 export 之前读。**
- `references/scraping.md` —— 分块策略、失败模式、图片插件那件事。**批量抓之前读。**
- `data/taxonomy.json` —— 分类词表。**改分桶时才读。**
- `examples/env.shared.example` —— 共享 `.env` 的键位说明。
