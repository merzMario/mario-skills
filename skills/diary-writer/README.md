# diary-writer

> Append-only 日记 entry writer for [Claude Code](https://docs.claude.com/en/docs/claude-code) skills + any Obsidian vault (or any markdown vault, really).

One call, one entry, one timestamped block in today's markdown file. That's it.

```bash
printf '%s' "今天去新房签了车位合同。" | bash scripts/diary_write.sh
# → {"ok":true,"action":"append","path":"journals/2026-10-05.md",...}
```

---

## 为什么要做

LLM 写日记最常出错的三类：

1. **手拼 markdown**：拼 frontmatter、算日期、转义引号 —— 一次对、十次错
2. **路径硬编码**：用户的 Vault 在 `~/Documents` 还是 iCloud？脚本猜，猜错就是污染
3. **触发词歧义**："记录" 是写文件还是记 SQL？是追加还是新建？

这个 skill 把所有"对"和"不对"的事情从 LLM 里搬出来：

- LLM 只做一件事：把用户的话用 `<<<` 喂给脚本
- 脚本负责：找 vault、找文件、判断新建/追加、算 ISO 周数、刷 frontmatter、备份、写盘、回执 JSON
- 重复检测基于内容 MD5，相同内容第二次进会 skip
- 任意单用户本地 Vault 可装，不用 Obsidian CLI、不用 Templater、不用 Python

---

## 30 秒上手

### 1. 装到任意 Claude Code skills 目录

把 `diary-writer/` 整个 copy 到 `~/.claude/skills/` 或项目的 `.claude/skills/` 下。

### 2. 初始化（一次性，人在终端跑）

```bash
bash ~/.claude/skills/diary-writer/scripts/diary_write.sh --init            # 真跑，写盘
bash ~/.claude/skills/diary-writer/scripts/diary_write.sh --init --dry-run  # 预览，零副作用
bash ~/.claude/skills/diary-writer/scripts/diary_write.sh --detect          # 仅列出 Obsidian 检测到的 vault
```

`--init` 会问 4 个问题：Vault 在哪、日记子目录叫什么、状态目录放哪、默认标签写啥。
答案存到 `~/.mario-skills/.env`（共享文件，写入时合并，不会覆盖其他技能的 key）。

**Vault 默认值自动从 Obsidian 的 `obsidian.json` 探测**（macOS / Linux / Windows 都支持）：

- 检测到 1 个 vault → 静默用为默认
- 检测到多个 vault → 列出编号让用户输 `1` / `2` 或直接输入路径
- 没检测到 → 退回 `~/Documents/Obsidian`

加 `--dry-run` 会走完所有提问，但**不写 config、不创建子目录**，最后打印一段 "Would write..." 的预览和 `Nothing was changed` 后退出 0。

`--detect` 只读 Obsidian 配置、不写任何东西、不进入 wizard —— 想先看一眼机器上有几个 vault 时用。

### 3. 让 Claude Code 自动调用

在 Claude Code 里说 "记一下今天..." 或 "记录今天的日记" 之类的话，LLM 会按 `SKILL.md` 里的契约自动调脚本：

```bash
printf '%s' "用户原话" | bash scripts/diary_write.sh
```

---

## 架构

```
┌─────────────────────────────────────────────────────────┐
│  LLM (Claude Code)                                      │
│  - 触发词命中 → 读 SKILL.md → 拿到调用契约              │
│  - 原文用 <<< 喂入，不拼 markdown、不算日期               │
└──────────────────────┬──────────────────────────────────┘
                       │ stdin: 原文
                       ▼
┌─────────────────────────────────────────────────────────┐
│  scripts/diary_write.sh                                 │
│  1. 读 config (XDG / env)                               │
│  2. 算 ISO 周数 / 中文星期                              │
│  3. MD5 去重                                            │
│  4. 文件不存在 → 用模板创建 + 拼 frontmatter + 标题     │
│  5. 文件存在 → 备份 + 追加带时间戳的块                   │
│  6. stdout 输出 JSON {ok, action, path, ...}             │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
            ${VAULT_DIR}/${JOURNALS_SUBDIR}/${YYYY-MM-DD}.md
```

**没有进程间状态**：每次调用都从磁盘读所有需要的。备份、`hash`、`log` 都放在 `$STATE_DIR`（默认 `~/.local/share/diary-obsidian`）。

**没有 Obsidian CLI 依赖**——`obsidian` 命令在你机器上其实是 `Obsidian.app` 的 binary，会挂起或忽略参数。第一版试过用它当首选 tier，发现 bug 已撤掉。

---

## 配置

配置只有一个文件：`~/.mario-skills/.env`。四个 key：

```ini
# 必填，Vault 根目录
VAULT_DIR=/Users/you/Documents/Obsidian
# 相对 VAULT_DIR，默认 journals
JOURNALS_SUBDIR=journals
# 哈希/日志/备份；XDG 默认 ~/.local/share/diary-obsidian
STATE_DIR=/Users/you/.local/share/diary-obsidian
# frontmatter tags；留空=不写
TEMPLATE_TAGS=日记,复盘
```

模板见 [`examples/env.shared.example`](examples/env.shared.example)。

---

## 共享 `.env`

`mario-skills` 里的所有技能共用两个 `.env` 文件。项目级覆盖用户级：

| 位置 | 作用域 |
|------|--------|
| `<项目>/.mario-skills/.env` | 项目级，优先 |
| `~/.mario-skills/.env` | 用户级，全局生效 |

```ini
# ~/.mario-skills/.env
VAULT_DIR=/Users/you/Documents/Obsidian
JOURNALS_SUBDIR=journals
STATE_DIR=/Users/you/.local/share/diary-obsidian
TEMPLATE_TAGS=日记,复盘

OPENAI_API_KEY=sk-...        # 其他技能的 key 放同一个文件
```

`diary-writer` 会忽略不认识的 key，其他技能同理 —— 各写各的 block，共用一个文件。

### 完整解析链

从高到低，逐 key 独立判定：

| # | 层 | 例子 |
|---|----|------|
| 1 | `process.env` | `VAULT_DIR=/x bash scripts/diary_write.sh` |
| 2 | `<项目>/.mario-skills/.env` | 项目级，共享 |
| 3 | `~/.mario-skills/.env` | 用户级，共享 |
| 4 | 内置默认值 | 脚本常量 |

只设 `VAULT_DIR` 不会让其他三个 key 掉回默认值 —— 每个 key 各自走一遍链。

### 初始化

```bash
bash scripts/diary_write.sh --init            # 写入 ~/.mario-skills/.env
bash scripts/diary_write.sh --init --project  # 写入 <cwd>/.mario-skills/.env
bash scripts/diary_write.sh --init --dry-run  # 预览
```

写入是**合并**，不是覆盖：文件里其他技能的 key、你自己写的注释都会原样保留，只更新 diary-writer 这四个。重跑 `--init` 时的默认值预填自当前解析值，显示的是你现在的真实配置。

### 从 v1 的 `config.ini` 迁移

v2.0.0 起不再读取 `~/.config/diary-obsidian/config.ini`。两种文件语法完全相同，**原样移动即可，无需改写**：

```bash
mkdir -p ~/.mario-skills
mv ~/.config/diary-obsidian/config.ini ~/.mario-skills/.env
bash scripts/diary_write.sh --config-info   # 确认来源变成 ~/.mario-skills/.env
```

### 查来源

```bash
bash scripts/diary_write.sh --config-info          # 人读
bash scripts/diary_write.sh --config-info --json   # 机读
```

```
  VAULT_DIR        /Users/you/Documents/Obsidian
  JOURNALS_SUBDIR  journals
  STATE_DIR        /Users/you/.local/share/diary-obsidian
  TEMPLATE_TAGS    日记,复盘

Sources (highest priority first):
  VAULT_DIR        ~/.mario-skills/.env
  JOURNALS_SUBDIR  ~/.mario-skills/.env
  ...

Search path:
  [1] process.env
  [2] /current/project/.mario-skills/.env  (absent)
  [3] /Users/you/.mario-skills/.env  (found)
```

配置全都没找到时，写入会返回 `config_not_found` 并在 `searched` 数组里列出**所有找过的位置**：

```json
{"ok":false,"error":"config_not_found","searched":["process.env","<cwd>/.mario-skills/.env","~/.mario-skills/.env"],"hint":"run: bash diary_write.sh --init"}
```

"写错 vault 了"这类问题的正确排查方式就是先跑 `--config-info`，看值到底来自哪一层。

---

## .env 语法

- `KEY=VALUE`，一行一个；空行和 `#` 注释忽略
- 可选的 `export ` 前缀会被接受
- 值可用配对引号包住以保留首尾空格
- **只按第一个 `=` 切分**，所以值里可以含 `=`
- 同一个文件里后定义的覆盖先定义的
- 支持 CRLF 换行

**值是被解析的，不会当 shell 执行。** `$(...)`、反引号、`;` 都按字面文本存下来 —— 这个文件无法执行代码。这是有意为之：`.env` 里可能放着 API key，不能给它 `source` 的机会。

`.mario-skills/` 已在仓库 `.gitignore` 里，凭据不会被提交。

---

## 已知边界

- **Chinese-specific cleaning** —— 脚本里有一段 sed 把"作为一名"/"总而言之"/"我我我"洗掉。**非中文作者请审阅这段或直接删掉**（`scripts/diary_write.sh` 第 252 行附近的 `CLEANED=$(...)`）。
- **Day-of-week 写死中文（一/二/.../日）** —— 标题里 `星期${WEEKDAY_CN}` 是中文格式。非中文作者请改 `WEEKDAY_CN` 映射。
- **每天一个文件** —— 不支持跨天合并、不支持多日记并行。
- **改 `.mario-skills/.env` 后立即生效** —— 不需要重启任何东西；下次调用时读盘。
- **不在 v0 范围**：移动端 / 锁文件 / 多 Vault 合并 / 日记导出。
- **大小写不敏感路径补全** —— init 向导里默认开启（用 `INPUTRC` 临时文件加载）。如果在你的 macOS bash 上仍不生效（输入 `~/lib` + Tab 不能补全 `~/Library`），把下面这两行加进 `~/.inputrc`，影响所有 bash 会话：
  ```
  set completion-ignore-case on
  set show-all-if-ambiguous on
  ```
  写完后新终端生效；当前终端 `Ctrl+X Ctrl+R` 重读。
- **Vault 探测局限** —— `--detect` 和 init 的自动默认从 Obsidian 自己的 `obsidian.json` 读取。如果该文件不存在、损坏、或只包含已被删除的 vault，会读不到、不会报错而是退回 `~/Documents/Obsidian` 默认值。
  - 如果你有 vault 但探测不到：检查 `~/Library/Application Support/obsidian/obsidian.json` 是否存在且包含 `"vaults"` 键
  - 如果探测到的 vault 在磁盘上已不存在（`✗ (missing)`），手动指定路径即可

---

## 仓库结构

```
diary-writer/
├── SKILL.md                    # Claude Code 读这份知道怎么调
├── scripts/
│   └── diary_write.sh          # 唯一可执行文件
├── templates/
│   └── diary-template.md       # 正文骨架模板（不含 frontmatter）
├── examples/
│   └── env.shared.example      # 共享 .mario-skills/.env 模板（含全部 key + 注释）
├── LICENSE                     # MIT
└── README.md                   # 本文件
```

---

## License

MIT — see [LICENSE](LICENSE).