# wewrite

微信公众号内容管道，产出直接落进 Obsidian Vault。

上游：[imraywang/wewrite](https://github.com/imraywang/wewrite)（MIT），
本副本移植自 [merzMario/wewrite](https://github.com/merzMario/wewrite)。

## 为什么需要它

一个公众号文章从选题到草稿箱，中间要处理十几次文件读写：建任务目录、算 run id、
把初稿和成稿分开写、记来源台账、封存后锁定正文、再叠加配图和预览。

让 LLM 自己拼这些路径，结果是同一篇文章写十次有十种落盘位置，重跑一次覆盖
上一次，成稿和初稿互相覆盖，凭证不小心写进 git 仓库。

这个 skill 的立场：**确定性操作全部由脚本做，LLM 只负责判断和路由。**
日期、路径、去重、frontmatter、原子写入、封存校验，全在 Python CLI 里。

## 改造了什么

相对上游 wewrite 4.2.1，两处改造。

### 1. 产出与状态分根

上游只有一个根 `WEWRITE_HOME`，凭证和文章产物混在一起。这对 vault 场景是致命的：
vault 既是 git 仓库又被 iCloud 同步。

现在拆成两个根：

| 根 | 环境变量 | 默认 | 装什么 |
|----|----------|------|--------|
| 状态根 | `WEWRITE_HOME` | `~/.wewrite` | 凭证、风格、历史、playbook、学习语料 |
| 产出根 | `WEWRITE_OUT_DIR` | `$VAULT_DIR/output/WeWrite` | `runs/<run_id>/` 下的全部写作产物 |

`paths.py` 多了一个 `out_dir()`，`runs.py` 把 artifacts 路径改成相对产出根。
改一个环境变量，整条管线搬家。

**`config.yaml` 和任何密钥永远不会落在产出根下。** 这是硬边界。

### 2. 配置走 mario-skills 共享 `.env`

上游用 `~/.wewrite/config.yaml`。现在改成读 mario-skills 全市场共享的
`.mario-skills/.env`，四级查找链，沿用 baoyu-skills 的溯源纪律：

```
process env  →  <cwd>/.mario-skills/.env  →  ~/.mario-skills/.env  →  内置默认
```

三条规则（`envconf.py` 里有实现和理由）：

- **只解析，绝不 `source`。** 装密钥的文件一旦被 source，等于把任意代码执行权
  交给它。按行读，剥一层配对引号，值当字面量存。
- **逐键解析。** 只设 `WEWRITE_THEME` 不会重置 `WECHAT_APPID`。
- **不认识就跳过。** 同一个文件还服务 `diary-writer`、`dankoe-letters-fetch`，
  看到不属于自己的键必须无动于衷。

上游的 `config.yaml` 保留为最后一层兜底，老配置不会失效。

## 30 秒上手

```bash
# 一次性安装（人跑）
bash scripts/wewrite.sh --setup      # 建 .venv 装依赖
bash scripts/wewrite.sh --init       # 写 ~/.mario-skills/.env，自动探测 VAULT_DIR

# 补上公众号凭证（人跑，编辑 ~/.mario-skills/.env）
# WECHAT_APPID=wx...
# WECHAT_SECRET=...

# 确认配置从哪来
bash scripts/wewrite.sh --config-info
```

之后在 Claude Code 里说「写一篇公众号」就行。

## 架构

```
用户
 │
 ▼
SKILL.md ── 路由与判断（LLM）
 │
 ▼
scripts/wewrite.sh ── 解析 .mario-skills/.env → 设环境变量 → 转发
 │                   --init / --detect / --setup / --config-info
 ▼
scripts/wewrite_cli/wewrite/ ── Python CLI，全部确定性操作
 ├── envconf.py      .mario-skills/.env 四级查找 + 溯源
 ├── paths.py        状态根 / 产出根
 ├── runs.py         run 生命周期、封存校验
 ├── commands/       诊断、评分、热点、SEO、数据、学习……
 └── toolkit/        排版、微信 API、生图、主题
 │
 ├──────────────►  $WEWRITE_HOME        ~/.wewrite（凭证 / 风格 / 历史）
 │
 └──────────────►  $WEWRITE_OUT_DIR     $VAULT_DIR/output/WeWrite（成稿 / 配图 / 预览）
```

## 产出布局

```
output/WeWrite/runs/<run_id>/
├── article.md              成稿，封存后不可改写
├── draft.md                初稿
├── brief.yaml              任务书
├── claims.yaml             事实主张清单
├── sources.yaml            来源台账
├── review-report.json      审稿报告
├── article-illustrated.md  带图副本
├── image-prompts.md        图片提示词
├── images/                 生成的图片
├── preview.html            微信预览
└── state.yaml              run 状态
```

`state.yaml` 里的 artifacts 是**相对产出根**的路径，所以整个 `runs/` 目录
换个位置，旧状态依然解析得到。

## 配置

写在 mario-skills 共享的 `.mario-skills/.env`。完整注释见
[`examples/env.shared.example`](./examples/env.shared.example)。

最小配置只要一行 —— 产出落点由 `VAULT_DIR` + `WEWRITE_OUT_SUBDIR` 拼出：

```bash
VAULT_DIR=/Users/you/Documents/Obsidian
WEWRITE_OUT_SUBDIR=output/WeWrite
```

想让产出进 `02-Output/02-Platforms/微信公众号`，只改 `WEWRITE_OUT_SUBDIR` 一行。

## 依赖

需要一个装了 `pyyaml`、`requests`、`markdown`、`beautifulsoup4`、`cssutils`、
`Pygments`、`Pillow` 的 Python 3.11+。

`scripts/wewrite.sh` 会按顺序探测并挑第一个能 import 的解释器：

1. `$WEWRITE_PYTHON`（显式指定）
2. `<skill>/.venv/bin/python`（`--setup` 建的）
3. `~/.local/share/uv/tools/wewrite/bin/python`（上游 uv tool）
4. `PATH` 上的 `python3`

都找不到就退出码 3，并提示人跑 `--setup`。**macOS 自带的 python3 没有 yaml，
所以这一条探测不是多余的。**

## 已知边界

- **默认落在 `output/WeWrite/`，符合本 vault 对 `output/` 的定义**（`CLAUDE.md`：
  「输出内容的保存路径」）。`raw/` 按 vault 约定是「原始素材，不可变」，所以没往那里写。
  想换成 `02-Output/02-Platforms/微信公众号`，改 `WEWRITE_OUT_SUBDIR` 即可，不需要动代码。
- **未配置公众号凭证时不能推草稿箱**，只会生成本地预览。这是设计，不是 bug。
- **`fetch-article` 的浏览器抓取路径需要 Playwright**，默认不装，会降级到
  `requests` 路径。要装的话 `pip install "wewrite[browser]"`。
- **图片生成本地要花钱。** `max_images` 和 `max_cost` 是硬上限，别绕过。
- **`--init` 不会覆盖已存在的键。** 想改配置直接编辑文件。
- 版本号跟上游分叉了。本副本是 `4.2.1-mario.1`，同步上游时需要手工合并
  `paths.py` 和 `envconf.py` 两处。

## License

MIT，见 [LICENSE](./LICENSE)。上游 wewrite 亦为 MIT。
