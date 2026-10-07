---
name: diary-writer
description: 记录日记。当用户说"记录 / 写日记 / 记一下 / 今天的日记 / 记录日记 / 记日记"任何之一时使用。
---

# diary-writer

> 日记 append-only 写入器。配置驱动，可放任意单用户本地 Vault。

---

## 一、首次使用（必须由人执行一次）

`diary-writer` 需要知道 Vault 在哪。任一层配置命中即可（完整优先级见第三节）；如果脚本返回 `config_not_found`，**引导用户执行**：

```bash
bash scripts/diary_write.sh --init            # 真跑，写 ~/.mario-skills/.env
bash scripts/diary_write.sh --init --project  # 写 <cwd>/.mario-skills/.env，仅当前项目生效
bash scripts/diary_write.sh --init --dry-run  # 预演，只显示将要写什么
bash scripts/diary_write.sh --detect          # 仅列出 Obsidian 检测到的 vault
```

`--init` 写入合并 —— 该文件里其他技能的 key 和你自己的注释都会保留，只更新 diary-writer 这四个。默认值预填自当前已解析出的值，所以重跑显示的是你现在的真实配置。

`--init` 依然不是 LLM 该跑的东西。

`--init` 会问四个问题：Vault 目录、日记子目录、状态目录、默认标签：
- Vault 默认值自动从 Obsidian 的 `obsidian.json` 探测（macOS / Linux / Windows 都支持）
  - 检测到 **1 个** vault → 静默用为默认
  - 检测到 **多个** vault → 列出编号让用户输 `1` / `2` 或路径
  - 没检测到 → 退回 `~/Documents/Obsidian`
- 路径字段支持 `~` 和 Tab 补全；用户错误输入 `\<空格>` 转义时自动还原
- 之后所有路径都从该配置派生，无需再设环境变量

`--dry-run` 让用户在确认 init 会改哪些文件时放心预览，**不会**写 config、**不会**创建子目录。走完所有提问后打印一段 "Would write..." 的预览和 `Nothing was changed`，然后退出 0。

`--detect` 只读 Obsidian 配置、不写任何东西、不进入 wizard —— 想先看一眼机器上有几个 vault 时用。

> ⚠️ **不要在 LLM 调用里跑 `--init` / `--detect`**。init 是给真人 CLI 跑的，配置好了再调下面的写入。`--dry-run` / `--detect` 也是同理。

---

## 二、LLM 调用方式

**写入动作完全由 `scripts/diary_write.sh` 接管**。LLM **不做**：

- ❌ 读 SKILL.md / 模板
- ❌ 计算 Templater 占位符（ISO 周数、中文星期）
- ❌ 构造完整 markdown
- ❌ 直接调 `obsidian create` / `obsidian append`
- ❌ 写 shell heredoc 拼内容
- ❌ 询问用户 Vault 位置（那应该走 --init，LLM 没那个上下文）

LLM **只做**：

1. 收到用户原文，调 `bash scripts/diary_write.sh <<< 'X'`
2. 读 JSON 报告（stdout），回执用户
3. JSON 含 `error: config_not_found` → **不要自动跑 --init**，告诉用户执行一次
4. JSON 含其他 `error` → 兜底（重试 / 转 KB tool + /tmp）

---

## 三、配置解析（优先级从高到低）

| # | 层 | 位置 | 归属 |
|---|----|------|------|
| 1 | `process.env` | `VAULT_DIR=/x bash diary_write.sh` | 单次调用 |
| 2 | 项目级 `.env` | `<cwd>/.mario-skills/.env` | **所有 mario 技能共用** |
| 3 | 用户级 `.env` | `~/.mario-skills/.env` | **所有 mario 技能共用** |
| 4 | 内置默认值 | 脚本常量 | — |

`.mario-skills/.env` 是**唯一**配置文件，也是整个 marketplace 共用的约定：仓库里每个技能都读同样这两个文件，所以一个 key 或路径只写一次，所有技能都能看到。四个 key（`VAULT_DIR` / `JOURNALS_SUBDIR` / `STATE_DIR` / `TEMPLATE_TAGS`）拼写在各层完全一致。

**逐 key 独立解析**，不是全有或全无：只设 `VAULT_DIR` 不会让其他三个 key 丢失。

> ⚠️ v2.0.0 起不再读取 `~/.config/diary-obsidian/config.ini`。旧用户把内容原样搬到 `~/.mario-skills/.env` 即可，两种文件语法相同，纯文件移动无需改写。

### 查配置来源（排错用）

```bash
bash scripts/diary_write.sh --config-info           # 人读：值 + 来源 + 各层是否存在
bash scripts/diary_write.sh --config-info --json    # 机读
```

输出会明确标出每个值来自哪一层 —— 用户说"写错 vault 了"时，先跑这个，不要猜。

配置全都没找到时，写入路径会返回 `config_not_found`，并在 `searched` 数组里列出**所有找过的位置**。把 `searched` 原文转述给用户，不要只说"没配置"。

---

## 四、模板章节结构

模板**只含正文骨架**（不含 frontmatter、不含标题——这两个由脚本现场拼）。

| 模块 | 章节标题 | 填法 |
|------|---------|------|
| **日记原文** | `## 日记原文（原始记录 / 多次分段）` | ✅ **唯一模块**：脚本自动追加（带时间戳）|

frontmatter（`date` / `week` / `tags`）和标题（`# 📅 YYYY-MM-DD 星期X`）由脚本拼装，模板里不要写死。

---

## 五、核心边界

1. **不评价 / 不分析 / 不改写原意** —— 原文怎么发，存进去就是什么
2. **不修改"日记原文"模块外的章节** —— 脚本只动 frontmatter / 标题 / 模块头 / 时间戳块
3. **不修改用户的 `.mario-skills/.env`** —— LLM 永远不该写配置；如需改配置，让用户重跑 `--init`

---

## 六、绝对禁止

- ❌ 当配置不存在时 LLM 自动调 `--init`（init 是给人跑的，LLM 没交互式终端）
- ❌ 当配置不存在时直接 `exit 1` 让用户建——必须自己用模板写 `--init`
- ❌ 在日记原文里添加 AI 分析、改写原意
- ❌ 写到日记原文以外的任何模块
- ❌ 假设 vault 是 iCloud Vault（必须走 config）
- ❌ 自己读 `.mario-skills/.env` 来取配置 —— 交给脚本解析
- ❌ 打印、回显或写进任何文件 `.mario-skills/.env` 里的值（那是共享凭据文件，可能含 API key）
- ❌ 往 `.mario-skills/.env` 写任何东西（连注释和空行都不要）—— 那是人负责的文件
- ❌ 手写 `VAULT_DIR=...` 之类的环境变量去"修"配置 —— 层 1 会静默压过用户所有配置，优先用 `--config-info` 定位问题