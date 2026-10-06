# mario-skills

[English](./README.md) | 中文

面向 Obsidian Vault 工作流和本地优先写作的个人 Agent 技能集，以 Claude Code 插件 marketplace 形式分发。

这里的技能遵循同一个原则：**文件操作交给脚本，LLM 只负责路由。** 日期计算、路径解析、去重、frontmatter 拼装、备份 —— 这些都该写在可测试的 shell 脚本里，而不是交给一个偶尔算对一次、错九次的语言模型。

## 安装

> **提示**：按需安装，别一次性全装 —— 每个装上的 skill 都会在 Agent 每次运行时占用额外上下文。

### 注册为插件 Marketplace

在 Claude Code 里执行：

```bash
/plugin marketplace add merzMario/mario-skills
```

### 安装技能

**方式 1：浏览界面**

1. `/plugin` → **Browse and install plugins**
2. 选 **mario-skills**
3. 选 **mario-skills** 插件
4. 点 **Install now**

**方式 2：直接安装**

```bash
/plugin install mario-skills@mario-skills
```

**方式 3：直接跟 Agent 说**

> 从 github.com/merzMario/mario-skills 安装技能

### 单个技能独立安装

每个技能都是自包含的，可以单独安装：

```bash
npx skills add merzMario/mario-skills
```

或者直接 copy 技能目录到对应运行时的 skills 位置：

```bash
# 用户级
cp -R skills/diary-writer ~/.claude/skills/

# 项目级
cp -R skills/diary-writer <project>/.claude/skills/
```

## 共享配置

所有技能共用同样两个 `.env` 文件。一个 key 只写一次，所有技能都能看到。

| 优先级 | 位置 | 作用域 |
|--------|------|--------|
| 1 | `KEY=value bash script.sh` | 单次调用 |
| 2 | `<项目>/.mario-skills/.env` | 该项目，覆盖用户级 |
| 3 | `~/.mario-skills/.env` | 所有项目 |
| 4 | 技能自己的 `config.ini` | 仅该技能 |
| 5 | 内置默认值 | — |

```ini
# ~/.mario-skills/.env
VAULT_DIR=/Users/you/Documents/Obsidian   # diary-writer 读这个
OPENAI_API_KEY=sk-...                     # 谁需要谁读自己的
```

- 一个共享文件，各技能一个 block。技能会忽略自己不认识的 key。
- 值是**被解析的，不会被 source** —— `.env` 里的 `$(...)` 和 `;` 按字面文本存下，所以凭据文件无法执行代码。
- `.mario-skills/` 已在 `.gitignore` 里。
- 凡是需要读配置的技能都提供 `--config-info`，打印每个值以及它来自哪一层。"写错地方了"这类问题一条命令就能定位。

每个技能的 README 里写明自己的 key。加新技能见 [`docs/creating-skills.md`](./docs/creating-skills.md)。

## 可用技能

所有技能都挂在同一个 `mario-skills` 插件下。

### Vault 写作类

读写本地 markdown Vault 的技能。

| 技能 | 说明 |
|------|------|
| [`diary-writer`](./skills/diary-writer) | append-only 日记写入器。一次调用往当天文件追加一个带时间戳的块。配置发现、ISO 周数、MD5 去重、备份、JSON 回执全在脚本里。 |

## 更新技能

1. 在 Claude Code 里执行 `/plugin`
2. 切到 **Marketplaces** 标签
3. 选 **mario-skills**
4. 选 **Update marketplace**

也可以开启 **Enable auto-update** 自动跟版本。

## 仓库结构

```
mario-skills/
├── .claude-plugin/
│   └── marketplace.json      # marketplace + 插件清单（唯一事实来源）
├── .github/workflows/
│   └── validate.yml          # CI：清单/技能漂移检查
├── docs/
│   └── creating-skills.md    # 技能编写 SOP
├── scripts/
│   └── validate-marketplace.mjs
├── skills/
│   └── diary-writer/         # 一个技能一个目录
│       ├── SKILL.md          # 给 Agent 看的调用契约
│       ├── README.md         # 给人看的文档
│       ├── scripts/
│       ├── templates/
│       ├── examples/
│       └── LICENSE
├── CLAUDE.md                 # 仓库作者指南
├── CHANGELOG.md
└── LICENSE
```

## 贡献一个技能

完整 SOP 见 [`docs/creating-skills.md`](./docs/creating-skills.md)。速查版：

1. 建 `skills/<技能名>/SKILL.md`，frontmatter 写 `name` + `description`
2. 逻辑全放 `scripts/`，示例配置放 `examples/`，骨架放 `templates/`
3. 在 `.claude-plugin/marketplace.json` 里注册技能路径
4. 两个 README 的技能表各加一行
5. 跑 `npm run validate`
6. 提交并打 tag

## 校验

```bash
npm run validate
```

以下情况会失败：技能目录存在但没注册、frontmatter `name` 和目录名不一致、清单格式错误、`SKILL.md` 里链接到了技能目录之外。

## License

MIT —— 见 [LICENSE](./LICENSE)。每个技能目录里另有自己的 LICENSE。