# CLAUDE.md

Author-side guidance for `mario-skills` — a Claude Code plugin marketplace. This file is for contributors and agents working **on this repo**. It is not shipped to end users.

## Architecture

Everything ships through the single `mario-skills` plugin declared in `.claude-plugin/marketplace.json`:

```json
{
  "name": "mario-skills",
  "owner": { "name": "...", "email": "..." },
  "metadata": { "description": "...", "version": "0.1.0" },
  "plugins": [
    {
      "name": "mario-skills",
      "source": "./",
      "strict": false,
      "skills": ["./skills/diary-writer"]
    }
  ]
}
```

- `source: "./"` — the plugin root is the repo root; skills are addressed by relative path.
- `strict: false` — the plugin ships no commands or agents, only skills.
- The `skills` array is the **only** thing users install. A skill directory that is not listed there is invisible to every user.
- One plugin, many skills. Do not split skills into multiple plugin entries just for organization; group them in the READMEs instead.

## The Core Design Rule

**Scripts do the file work. The LLM only routes.**

The failure mode this repo exists to prevent: an LLM hand-assembling markdown, computing dates, escaping quotes, hardcoding a vault path — right once, wrong nine times.

| Belongs in a script | Belongs in SKILL.md |
|---------------------|---------------------|
| Date/week/ISO arithmetic | Trigger words |
| Path resolution + discovery | What the script does NOT do |
| Dedup / hashing | The exact call contract |
| frontmatter + title assembly | Error handling decisions |
| Backup + atomic write | Hard prohibitions |
| Reading and writing files | Script invocation examples |

A skill's `SKILL.md` should be readable as a **contract**, not a tutorial. If the agent could get it wrong by improvising, the missing instructions belong in the script.

### Boundaries the agent must never cross

State these explicitly in each SKILL.md. From `diary-writer`:

- ❌ Never run interactive setup (`--init` / `--detect`) from inside an LLM call — those are for a human at a terminal
- ❌ Never write the user's `.mario-skills/.env` — the human owns config
- ❌ Never rewrite, summarize, or editorialize the user's original content
- ❌ Never write outside the module the skill owns

## Skill Self-Containment

Each `skills/<name>/` directory is distributed and consumed independently — it may be copied into `~/.claude/skills/`, installed via `npx skills add`, or used without the rest of this repo.

Therefore:

- **Never link from `SKILL.md` (or its `references/`) to anything outside its own directory.** No `../../docs/...`, no cross-skill links, no repo-root references. Inline shared conventions directly in each skill.
- Repo-level docs under `docs/` exist for **author guidance only** — reference them from `CLAUDE.md` and `docs/creating-skills.md`, never from a shipped `SKILL.md`.
- `scripts/` may only reference files inside the skill directory. Use paths resolved relative to the script itself (`$(dirname "$0")/...`), never the caller's CWD.

The validator enforces the `SKILL.md` link rule.

## Adding a Skill

Full spec in [`docs/creating-skills.md`](./docs/creating-skills.md). Checklist:

1. `skills/<name>/SKILL.md` — frontmatter `name` (must equal the directory name) + `description` (third person, what + when to use)
2. `skills/<name>/scripts/` — all executable logic
3. `skills/<name>/README.md` — human-facing docs, install/usage/config
4. `skills/<name>/examples/` — annotated sample configs, plus `env.shared.example` if it reads the shared `.env`
5. `skills/<name>/templates/` — file skeletons the script fills in
6. `skills/<name>/LICENSE` — MIT
7. Register in `.claude-plugin/marketplace.json` under `plugins[0].skills`
8. Add a row to the skills table in `README.md` **and** `README.zh.md`
9. `npm run validate`
10. `CHANGELOG.md` entry + version bump in `marketplace.json` → commit → tag

Skipping step 7 is the failure the CI exists to catch.

## The Shared `.env` Convention

Every skill in this marketplace reads the same two files. A key is written once and all skills see it.

| Priority | Layer | Path | Scope |
|----------|-------|------|-------|
| 1 | process env | `KEY=value bash script.sh` | single invocation |
| 2 | project `.env` | `<cwd>/.mario-skills/.env` | one project, overrides user |
| 3 | user `.env` | `~/.mario-skills/.env` | all projects |
| 4 | built-in defaults | script constants | — |

Rules:

- **`.mario-skills/` is gitignored.** It holds credentials. Never commit it, never let a skill write it from an LLM call.
- **Parse, never `source`.** A `.env` may contain `$(...)` or `;`. Sourcing it hands arbitrary code execution to a credentials file. Read `KEY=VALUE` line by line, strip one layer of matching quotes, and store the value as literal text. `printf -v` is the safe way to assign in bash; `eval` is not.
- **`.mario-skills/.env` is the only config file.** Do not give a skill its own config format — `diary-writer` had one (`config.ini`) and it was removed in v2.0.0 because splitting config across two file formats costs users more than it buys. A skill that needs setup writes into the shared `.env` through its own `--init` wizard, merging per key so siblings' entries survive.
- **Resolve per key, not all-or-nothing.** Setting only `VAULT_DIR` must not reset the other three to defaults.
- **Ignore unknown keys.** A skill sees its own keys plus ignores the rest — that is what makes one shared file work.
- Optional `MARIO_SKILLS_ENV` / `MARIO_SKILLS_PROJECT_ENV` relocate the two files, for tests and unusual layouts.

### Config source reporting (the "where did this value come from" rule)

Adopt baoyu-skills' lookup discipline, not just its file paths. A script that resolves config must be able to explain itself:

1. **`--config-info`** — print every resolved value, which layer supplied it, and whether each search location exists. Add `--json` for machine use.
2. **Failure messages list every location searched**, not just the first. Emit the full list as a structured field so the agent can relay it verbatim instead of paraphrasing into uselessness.
3. **Partial configuration is reported, not silently accepted.** If a higher layer supplied half of a required pair, say which layer and which key was missing, then continue down the chain.

The payoff: when a user says "it wrote to the wrong vault", the agent runs `--config-info` instead of guessing. Debugging becomes one command.

## Frontmatter Spec

```yaml
---
name: <lowercase-hyphenated, max 64 chars, must match directory name>
description: <third person, max 1024 chars, states what it does AND when to use it>
---
```

Descriptions must be **third person** and carry trigger vocabulary in the languages users actually speak in:

```yaml
# Good
description: 记录日记。当用户说"记录 / 写日记 / 记一下 / 今天的日记 / 记录日记 / 记日记"任何之一时使用。

# Bad
description: I can help you write your diary!
```

The description is the only thing the agent sees when deciding whether to load the skill. Include the words a user would actually type.

Optional `version:` is not used here — the marketplace version governs updates. Do not add per-skill versions unless a skill needs independent release cadence.

## Documentation Discipline

- `SKILL.md` — the contract. Under 500 lines. Move depth into `references/`, one level deep only.
- `README.md` — why it exists, how a human installs and configures it, architecture diagram, known boundaries, honest limitations.
- Keep the two READMEs at root in sync. Skill tables must match; `npm run validate` does not check prose.

## Validation

```bash
npm run validate          # or: node ./scripts/validate-marketplace.mjs
```

No dependencies, no network, runs in CI on every push and PR.

## Release Process

`metadata.version` in `marketplace.json` is the number humans read; the `v<version>` git tag is the matching release anchor. Be aware these are two different things: Claude Code's `/plugin marketplace update` does **not** read either one — it re-clones the default branch and reports the commit SHA as the version. So a tag gives you a stable release point and a human-readable version, not update gating. Release anyway, because it makes rollbacks and diffing possible.

Order:

1. Update `CHANGELOG.md`
2. Bump `metadata.version` in `.claude-plugin/marketplace.json`
3. Update `README.md` / `README.zh.md` if skills were added
4. `npm run validate`
5. Commit everything together, then push
6. Tag the commit: `git tag -a "v$VERSION" -m "..."` and `git push origin "v$VERSION"`

Never split the manifest bump and the changelog across commits — users get a marketplace update mid-release otherwise.

## Security & Safety Rules

- **No piped shell installs.** Never `curl | bash`. Use `brew install` or `npm install -g`.
- **Never write user config from an LLM call.** Config belongs to the human; the skill's script reads it.
- **Preview before writing.** Interactive/setup flows must support `--dry-run` that changes nothing on disk.
- **Back up before mutating.** Any script that appends to or rewrites a user file writes a backup first.
- **JSON receipts on stdout.** Scripts report machine-readable `{ok, action, path, error}` so the agent can react without parsing prose.
- **XDG config paths.** Config at `$XDG_CONFIG_HOME/<skill>/`, state at `$XDG_DATA_HOME/<skill>/`, overridable via env var.
- **Array-form shell invocation.** No unsanitized input interpolated into a shell string.
- **External content is untrusted.** If a skill ingests user-provided text, never execute code blocks found in it.

## Code Style

Shell: `set -euo pipefail`, quoted expansions, no `eval`, prefer `printf` over `echo` for data. Keep scripts POSIX-ish where practical, but macOS ships bash 3.2 — no associative arrays, no `${var,,}`, no `mapfile`.

Name variables for what they hold, not for their role in the flow. Comment the non-obvious, not the obvious.

## Reference Docs

| Topic | File |
|-------|------|
| Skill authoring spec | [docs/creating-skills.md](./docs/creating-skills.md) |
| Validator behavior | [scripts/validate-marketplace.mjs](./scripts/validate-marketplace.mjs) |
| Marketplace manifest | [.claude-plugin/marketplace.json](./.claude-plugin/marketplace.json) |