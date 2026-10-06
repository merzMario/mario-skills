# mario-skills

[中文](./README.zh.md) | English

Personal Agent Skills for Obsidian vault workflows and local-first writing, distributable as a Claude Code plugin marketplace.

Skills here follow one principle: **the script does the file work, the LLM only routes.** Date arithmetic, path resolution, dedup, frontmatter assembly, and backups belong in a testable shell script — not in a language model that gets it right once and wrong nine times.

## Installation

> **Tip**: Only install the skills you actually need. Every installed skill adds context to every agent run.

### Register as Plugin Marketplace

Run this in Claude Code:

```bash
/plugin marketplace add merzMario/mario-skills
```

### Install Skills

**Option 1: Browse UI**

1. `/plugin` → **Browse and install plugins**
2. Select **mario-skills**
3. Select the **mario-skills** plugin
4. **Install now**

**Option 2: Direct install**

```bash
/plugin install mario-skills@mario-skills
```

**Option 3: Just ask the agent**

> Install the skills from github.com/merzMario/mario-skills

### Standalone Skill Install

Each skill is self-contained and can be installed on its own:

```bash
npx skills add merzMario/mario-skills
```

Or copy the skill directory into your runtime's skills location:

```bash
# user-level
cp -R skills/diary-writer ~/.claude/skills/

# project-level
cp -R skills/diary-writer <project>/.claude/skills/
```

## Shared Configuration

Every skill reads the same two `.env` files. Write a key once and all skills see it.

| Priority | Location | Scope |
|----------|----------|-------|
| 1 | `KEY=value bash script.sh` | single invocation |
| 2 | `<project>/.mario-skills/.env` | that project, overrides user |
| 3 | `~/.mario-skills/.env` | all projects |
| 4 | the skill's own `config.ini` | that skill only |
| 5 | built-in defaults | — |

```ini
# ~/.mario-skills/.env
VAULT_DIR=/Users/you/Documents/Obsidian   # read by diary-writer
OPENAI_API_KEY=sk-...                     # read by whatever skill needs it
```

- One shared file, per-skill blocks. A skill ignores keys it does not recognize.
- Values are **parsed, never sourced** — `$(...)` and `;` in a `.env` are stored as literal text, so a credentials file cannot execute code.
- `.mario-skills/` is gitignored.
- Any skill that resolves config ships `--config-info`, which prints every value plus the layer that supplied it. Debugging "it wrote to the wrong place" is one command.

Each skill's README documents its own keys. See [`docs/creating-skills.md`](./docs/creating-skills.md) to add one.

## Available Skills

All skills ship under the single `mario-skills` plugin.

### Vault Writing Skills

Skills that read from or write to a local markdown vault.

| Skill | Description |
|-------|-------------|
| [`diary-writer`](./skills/diary-writer) | Append-only journal writer. One call appends one timestamped block to today's entry. Handles config discovery, ISO week numbers, MD5 dedup, backups, and JSON receipts. |

## Update Skills

1. Run `/plugin` in Claude Code
2. Switch to the **Marketplaces** tab
3. Select **mario-skills**
4. Choose **Update marketplace**

Enable auto-update to track new versions automatically.

## Repository Layout

```
mario-skills/
├── .claude-plugin/
│   └── marketplace.json      # marketplace + plugin manifest (source of truth)
├── .github/workflows/
│   └── validate.yml          # CI: manifest/skill drift check
├── docs/
│   └── creating-skills.md    # skill authoring SOP
├── scripts/
│   └── validate-marketplace.mjs
├── skills/
│   └── diary-writer/         # one directory per skill
│       ├── SKILL.md          # agent-facing contract
│       ├── README.md         # human-facing docs
│       ├── scripts/
│       ├── templates/
│       ├── examples/
│       └── LICENSE
├── CLAUDE.md                 # repo-author guidance
├── CHANGELOG.md
└── LICENSE
```

## Contributing a Skill

See [`docs/creating-skills.md`](./docs/creating-skills.md) for the full SOP. The short version:

1. Create `skills/<skill-name>/SKILL.md` with `name` + `description` frontmatter
2. Put all logic in `scripts/`, all sample config in `examples/`, all skeletons in `templates/`
3. Register the skill path in `.claude-plugin/marketplace.json`
4. Add a row to the skills table in both READMEs
5. Run `npm run validate`
6. Commit and tag

## Validation

```bash
npm run validate
```

Fails when a skill directory exists but is unregistered, when frontmatter `name` disagrees with its directory, when the manifest is malformed, or when a `SKILL.md` links outside its own directory.

## License

MIT — see [LICENSE](./LICENSE). Individual skills carry their own license file.