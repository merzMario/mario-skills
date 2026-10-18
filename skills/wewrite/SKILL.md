---
name: wewrite
description: 微信公众号内容管道：选题 → 任务书与证据 → 初稿 → 编辑成稿，配图、排版、推草稿箱按需追加。产出全部落进 Obsidian Vault 的 output/WeWrite/。用户说「写公众号」「写一篇公众号」「公众号」「微信推文」「草稿箱」「配个封面」「排版」「改成小红书/抖音」「看看文章数据」「学我的修改」时使用。不用于通用博客、邮件、纯 SEO 或与公众号无关的写作。
---

# wewrite — 公众号内容管道（Obsidian Vault 版）

从选题到草稿箱的一条流水线。**确定性操作全部由 `scripts/wewrite_cli/` 里的
Python CLI 完成，LLM 只负责路由和判断。**

产出根默认解析成 `$VAULT_DIR/output/WeWrite/`。每篇文章一个独立 run 目录：

```
output/WeWrite/runs/<run_id>/
├── article.md              成稿（封存后不可改写）
├── draft.md                初稿
├── brief.yaml              任务书
├── claims.yaml             事实主张清单
├── sources.yaml            来源台账
├── review-report.json      审稿报告
├── article-illustrated.md  带图副本
├── image-prompts.md        图片提示词
├── images/                 生成的图片
└── preview.html            微信预览
```

---

## 一、调用契约

**所有脚本都在本 SKILL.md 所在目录的 `scripts/` 下。解析 skill 目录的方式是从
SKILL.md 的位置推导，不要依赖调用时的 CWD。**

```bash
S="$(cd "<本 SKILL.md 所在目录>" && pwd)"

bash "$S/scripts/wewrite.sh" <子命令> [参数…]     # 唯一入口
```

入口先把 `.mario-skills/.env` 解析进环境变量，再转发给 Python CLI。
**不要直接调 `python -m wewrite`，也不要调全局安装的 `wewrite` 命令** ——
那会绕过 `.env`，写进错误的目录。

| 入口参数 | 用途 | 谁跑 |
|---------|------|------|
| `<子命令>` | 正常管道命令 | agent |
| `--config-info [--json]` | 每个配置项的值、来源层、搜索路径 | agent |
| `--paths` | 只打印状态目录和产出目录 | agent |
| `--detect` | 环境自检 | **人** |
| `--init [--dry-run]` | 写 `~/.mario-skills/.env` | **人** |
| `--setup` | 建 `.venv` 并装依赖 | **人** |

> ⚠️ **`--init` / `--detect` / `--setup` 不要在 LLM 调用里跑。** 配置归人管。

stdout 是 JSON，人读信息在 stderr。脚本失败时退出码非零。

---

## 二、配置

配置走 mario-skills 共享的 `.mario-skills/.env`，和 `diary-writer`、
`dankoe-letters-fetch`、`dedao-course-sync` 同一份文件。四级查找链：

```
process env  →  <cwd>/.mario-skills/.env  →  ~/.mario-skills/.env  →  内置默认
```

本技能拥有的键（完整注释见 `examples/env.shared.example`）：

| 键 | 作用 | 默认 |
|----|------|------|
| `VAULT_DIR` | vault 绝对路径（**共享键**，日记等技能也用） | 无 |
| `WEWRITE_OUT_SUBDIR` | 产出在 vault 里的相对路径 | `output/WeWrite` |
| `WEWRITE_OUT_DIR` | 产出绝对路径，**压过上面两个** | 无 |
| `WEWRITE_HOME` | 状态根：凭证、风格、历史、学习语料 | `~/.wewrite` |
| `WECHAT_APPID` / `WECHAT_SECRET` | 公众号 API，推草稿箱必需 | 无 |
| `WECHAT_AUTHOR` | 默认署名 | 无 |
| `WEWRITE_IMAGE_PROVIDER` / `_API_KEY` / `_MODEL` | 图片生成 | 无 |
| `WEWRITE_THEME` | 排版主题 | `professional-clean` |
| `WEWRITE_WRITER_*` | 写作模型（可选，不配则 agent 自己写） | deepseek-chat |

**产出目录怎么算出来的**：`WEWRITE_OUT_DIR` 绝对路径优先；否则
`VAULT_DIR` + `WEWRITE_OUT_SUBDIR`；再否则退回 `$WEWRITE_HOME/output`
（未接入 vault 时的上游默认行为）。

`--config-info` 报告**每一层的来源**，包括哪些搜索位置存在、哪些不存在。
它报 `process.env` 就真的是进程环境变量，报 `built-in default` 就是没配。
不要相信自己的推测，以这条命令为准。

排错先查来源，不要猜：

```bash
bash "$S/scripts/wewrite.sh" --config-info          # 人读
bash "$S/scripts/wewrite.sh" --config-info --json   # 机读
bash "$S/scripts/wewrite.sh" --paths                # 只看两个目录
```

---

## 三、内容流程

### 0. 建任务

先跑 `diagnose`，看依赖和降级标记。缺风格文件是正常的首次设置，不是错误。

按用户原话选模式 —— **不要替用户升级权限**：

```bash
# 默认「写一篇」：不生图、不发布
bash "$S/scripts/wewrite.sh" run start --topic "{选题，可空}" --mode draft --visual-mode none

# 「完整制作」：正文先跑完并封存，之后再独立配图和预览
bash "$S/scripts/wewrite.sh" run start --topic "{选题，可空}" --mode complete --visual-mode none

# 「推到草稿箱」：用户明确授权了发布，但不因此自动生图
bash "$S/scripts/wewrite.sh" run start --topic "{选题，可空}" --mode publish --visual-mode none
```

把 diagnose 的标记和当天日期写进任务：

```bash
bash "$S/scripts/wewrite.sh" run update \
  --patch '{"flags": {"skip_publish": false, "skip_image_gen": false, "use_writer_model": false, "needs_onboard": false, "diagnosed_at": "YYYY-MM-DD"}}'
```

用户说「继续上次」时，先 `run list`，确认唯一任务后 `run resume <run_id>`。
**不要新建任务。**

### 1. 选题

用户已给选题就记录并跳过。否则执行选题：热点抓取、需求词频、历史表现、
搜索需求四路交叉，产出 10 个带评分的候选。细节见
[references/topic-selection.md](references/topic-selection.md)。

```bash
bash "$S/scripts/wewrite.sh" run step topic completed
```

### 2. 任务书与初稿

先写 `artifacts.brief`（任务书）和 `artifacts.claims`（事实主张），再把初稿
写进 `artifacts.draft`，网页素材同步记到本任务的 `sources.yaml`。

- 任务书结构：[references/article-brief.md](references/article-brief.md)
- 框架速查：[references/frameworks-quick.md](references/frameworks-quick.md)
- 正文加厚：[references/content-enhance.md](references/content-enhance.md)
- 写作人格：`templates/personas/*.yaml`
- **初稿不是成稿。**

### 3. 编辑审稿

主标准是事实、观点、实用性、账号声音、可读性 —— **工具分数只提示可能的问题，
不做决定**。发现能修的问题直接改稿并复审。

只有编辑决定为 `pass` **且** `artifacts.review_report` 显示
`publishable=true`，才允许把最终正文写进 `artifacts.article`。

- 审稿清单：[references/editorial-quality.md](references/editorial-quality.md)
- SEO 规则：[references/seo-rules.md](references/seo-rules.md)
- 反 AI 味系统：`scripts/wewrite_cli/wewrite/data/anti-ai-writing-system.md`

### 4. 封存正文

```bash
bash "$S/scripts/wewrite.sh" run finish
```

封存正文与来源并写入历史。**封存后原始正文不可改写**，但仍可追加配图、
预览和发布结果。

---

## 四、可选后续动作

配图、排版、发布都是正文完成之后的**独立动作**。不得为了排版或发布自动触发生图。

### A. 配图

用户说「配个封面」设 `visual.mode=cover`；说「完整配图」设 `full`；
只要提示词设 `prompts`；缺图片配置自动降级为提示词。
详见 [references/visual-guide.md](references/visual-guide.md)。

严格遵守 `max_images` 和 `max_cost`。生成的图片落在 run 目录的 `images/`，
带图副本写 `article-illustrated.md` —— **不得覆盖 `article.md`**。

### B. 排版与发布

优先排版带图副本，没有则排版原始正文。**不自动调用配图。**

用户本轮明确要求发布时先授权：

```bash
bash "$S/scripts/wewrite.sh" run permission publish allow   # 用户撤回用 deny
```

只有 `permissions.publish=true` **且**公众号凭证齐全 **且**封面存在时才推草稿箱；
其他情况一律生成本地预览。微信平台限制见
[references/wechat-constraints.md](references/wechat-constraints.md)。

### C. 多平台改写

把一篇真改写成小红书图文笔记或抖音口播稿，不是同义替换。调性见
`templates/platforms/*.yaml`，方法见
[references/multiplatform-rewrite.md](references/multiplatform-rewrite.md)。

### D. 学修改 / 范文 / 数据复盘

- **学修改**：把你的手改 diff 成 lessons。见
  [references/learn-edits.md](references/learn-edits.md)
- **重设风格**：见 [references/onboard.md](references/onboard.md) 和
  `templates/style.example.yaml`
- **数据复盘**：见 [references/effect-review.md](references/effect-review.md)

---

## 五、状态与产出的边界

**这是硬边界，不要绕过：**

| 目录 | 装什么 | 为什么 |
|------|--------|--------|
| `WEWRITE_HOME`（默认 `~/.wewrite`） | `config.yaml`、`style.yaml`、`history.yaml`、`playbook.md`、`corpus/`、`exemplars/`、`themes/`、`personas/` | 凭证和机器本地状态 |
| `WEWRITE_OUT_DIR`（默认 `$VAULT_DIR/output/WeWrite`） | `runs/<run_id>/` 下的全部写作产物 | 要进 vault 的内容 |

**`config.yaml` 和任何密钥永远不落在产出根下。** vault 是 git 仓库且被
iCloud 同步，密钥进去等于公开。

---

## 六、绝对禁止

- ❌ 在 LLM 调用里跑 `--init` / `--detect` / `--setup`
- ❌ 自己读或打印 `.mario-skills/.env` —— 用 `--config-info` 查
- ❌ 绕开 `scripts/wewrite.sh` 直接调全局 `wewrite` 或 `python -m wewrite`
- ❌ 把密钥、`config.yaml`、`style.yaml`、`history.yaml` 写进 vault 或产出根
- ❌ 改写、总结、润色已封存的 `article.md`
- ❌ 手算日期、路径、slug —— 这些由脚本负责
- ❌ 编辑没给 `pass` 就把正文当成稿
- ❌ 没拿到本轮明确授权就推草稿箱
- ❌ 把模型记忆包装成已核实的事实；搜索失败时删掉无法核实的数字和引述
- ❌ 在 SKILL.md 里链到本 skill 目录之外的文件

---

## 七、失败与恢复

步骤失败时记录：

```bash
bash "$S/scripts/wewrite.sh" run step <topic|write|review|visual|publish> failed --error "简短原因"
```

内容步骤失败时**保留当前任务**，下次恢复后只重做失败或未完成的步骤。
正文已封存时，配图或发布失败**不改变**文章的完成状态：发布失败回退到本地预览，
图片失败保留提示词。

**退出码**：`0` 成功；`1` 管道内失败；`2` 参数错；`3` Python 依赖缺失
（提示人跑 `--setup`，或用 `WEWRITE_PYTHON=<解释器>` 指定）。

---

## 八、验证

写完确认：

- 成稿落在 `$VAULT_DIR/output/WeWrite/runs/<run_id>/article.md`
- `bash "$S/scripts/wewrite.sh" --config-info` 里产出目录指向 vault
- 审稿报告 `decision=pass` 且 `publishable=true`
- vault 里没有新增任何密钥文件
