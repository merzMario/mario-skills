# Creating Skills

The SOP for adding a new skill to `mario-skills`. Read [`../CLAUDE.md`](../CLAUDE.md) first for the architecture and design rule.

## Hard Requirements

| Requirement | Detail |
|-------------|--------|
| `name` | Max 64 chars, lowercase letters/digits/hyphens, **must equal the directory name** |
| `description` | Max 1024 chars, third person, says what it does AND when to use it |
| `SKILL.md` body | Under 500 lines; move depth into `references/`, one level deep only |
| Self-containment | No links from `SKILL.md` to anything outside its own skill directory |
| Script style | `set -euo pipefail`, quoted expansions, no `eval`, portable to bash 3.2 |
| License | `skills/<name>/LICENSE` — MIT |

All of these are enforced by `npm run validate` except the first-row prose ones and script style.

## Step 1 — Scaffold the directory

```bash
mkdir -p skills/<name>/{scripts,examples,templates,references}
```

Only create the subdirectories you need. An empty `references/` is noise.

## Step 2 — Write `SKILL.md`

The frontmatter is all the agent sees when deciding whether to load the skill:

```yaml
---
name: <name>
description: <third person: what it does + when to use it + trigger words>
---
```

### Writing the description

The description is the routing signal. Include the words a user would actually type, in the languages they would actually type them in.

```yaml
# Good — states what + when + trigger vocabulary
description: 记录日记。当用户说"记录 / 写日记 / 记一下 / 今天的日记 / 记录日记 / 记日记"任何之一时使用。

# Good — English equivalent
description: Append-only journal writer. Use when the user says "journal", "diary", "log my day", or "record today".

# Bad — first person, no trigger words, no "when"
description: I can help you write your diary!
```

### Writing the body

The body is a **contract**, not a tutorial. Structure it as:

1. **The call contract** — the exact command, its arguments, its stdin, its stdout
2. **What the script does NOT do** — so the agent does not improvise around it
3. **Error handling** — what to do on each error code
4. **Hard prohibitions** — the boundary list, stated explicitly

Do not describe *how* the script works internally. The agent does not need to know how ISO week numbers are computed; it needs to know not to compute them itself.

State the human-vs-agent split explicitly where relevant. Interactive setup belongs to a human at a terminal:

> ⚠️ **Do not run `--init` / `--detect` from inside an LLM call.** Those are for the human running the CLI.

### Scripts section

If the skill has scripts, include resolution instructions that work regardless of the agent's CWD:

```markdown
## Script Directory

All scripts live in `scripts/` inside this skill directory.
Resolve the skill directory from the location of this SKILL.md file.
```

Inside `scripts/`, never rely on the caller's working directory:

```bash
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
```

## Step 3 — Write `README.md`

The human-facing document. Cover:

- Why the skill exists — what goes wrong without it
- 30-second quickstart
- Architecture diagram
- Configuration schema, with a link to `examples/env.shared.example`
- Known boundaries and honest limitations, including anything platform- or language-specific
- License

Be honest about limitations. `diary-writer/README.md` documents that its weekday mapping is Chinese-only and that non-Chinese users must edit it. That is more useful than silence.

## Step 4 — Config, examples, templates

| Directory | Contents |
|-----------|----------|
| `examples/` | Annotated sample configs, at minimum a minimal and a full version |
| `examples/env.shared.example` | Documented template for the shared `.mario-skills/.env`, if the skill reads it |
| `templates/` | File skeletons the script fills in. Never hardcode computed values here — a template that contains an ISO week number is a bug |
| `references/` | Depth moved out of `SKILL.md`, loaded on demand |

### If the skill needs config, it reads the shared `.env`

`.mario-skills/.env` is the only config file in this marketplace. Do not invent a new format or a new location. Read the two shared files, in this order:

```
process env  →  <cwd>/.mario-skills/.env  →  ~/.mario-skills/.env  →  defaults
```

Implement it with a parse-never-source reader, in bash:

```bash
# Prints KEY's value from a dotenv file; last definition wins.
# Parsing rather than `source`ing is load-bearing: a .env holding credentials
# must not be able to execute commands.
env_get() {
  local want="$1" file="$2" line key val found=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*\") val="${val:1:${#val}-2}" ;;
      \'*\') val="${val:1:${#val}-2}" ;;
    esac
    [ "$key" = "$want" ] && found="$val"
  done < "$file"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}
```

Use `printf -v` to store resolved values. **No `eval`, no `source`** — `eval "$key=$val"` re-parses the value and turns a credential file into a code-execution vector. Prefer passing the current value in as an argument over `${!key}` indirection, so a second call cannot mistake its own output for the process environment.

Copy this function verbatim into each skill. Skills must stay self-contained, so the loader cannot live in a shared `lib/` — only the *convention* is shared, which is how baoyu-skills does it too.

Skip keys the skill does not recognize. That is what lets one file serve every skill.

### Ship `--config-info`

Every skill that resolves config must be able to report where each value came from:

```bash
$ ./script.sh --config-info
  API_KEY       sk-live-abc
  MODEL         gpt-4o
  BASE_URL      https://api.example.com

Sources (highest priority first):
  API_KEY       ~/.mario-skills/.env
  MODEL         built-in default
  BASE_URL      built-in default

Search path:
  [1] process.env
  [2] /project/.mario-skills/.env  (found)
  [3] /Users/you/.mario-skills/.env  (found)
```

Support `--json` alongside it. And when config is missing entirely, the error must enumerate **every** location searched as a structured field, so the agent can relay it verbatim:

```json
{"ok":false,"error":"config_not_found","searched":["process.env","<cwd>/.mario-skills/.env","~/.mario-skills/.env"],"hint":"run: ./script.sh --init"}
```

Never have the agent parse or read the config files itself. The script answers; the agent relays.

## Step 5 — Register in the manifest

Add the skill path to `.claude-plugin/marketplace.json`, keeping the list alphabetical:

```json
"skills": [
  "./skills/diary-writer",
  "./skills/<new-skill>"
]
```

This is the only thing users install. Skip this and `npm run validate` fails, and the skill is invisible.

## Step 6 — Update both READMEs

Add a row to the skills table in `README.md` **and** `README.zh.md`. If it introduces a new category, add the category heading to both. The validator does not check prose — this is on you.

## Step 7 — Validate

```bash
npm run validate
```

Must print `marketplace.json OK`. The validator checks:

- `.claude-plugin/marketplace.json` parses, has `name` / `owner.name` / `plugins` / `metadata.version` (semver)
- every plugin has `name`, `description`, a `source` that exists on disk, and a non-empty `skills` array
- every registered skill path is a real directory containing `SKILL.md`
- frontmatter `name` matches the directory name and is valid kebab-case
- `description` exists and is under 1024 chars
- no `SKILL.md` links escape its own directory via `../`
- **no skill directory exists on disk without being registered** (drift — the silent failure)

## Step 8 — Release

```bash
# 1. CHANGELOG.md entry
# 2. bump metadata.version in .claude-plugin/marketplace.json
# 3. npm run validate
# 4. commit manifest + changelog + skill together
# 5. tag
```

Commit the manifest bump and the skill in the same commit. Users pulling a marketplace update mid-release get a manifest that references files that do not exist yet.

## Review Checklist

Before tagging:

- [ ] `npm run validate` passes
- [ ] Description names what it does, when to use it, and real trigger words
- [ ] Body states the exact call contract and what the script does NOT do
- [ ] Interactive setup is explicitly marked as human-only
- [ ] Hard prohibitions are listed, not implied
- [ ] No links from `SKILL.md` outside the skill directory
- [ ] Script uses `set -euo pipefail`, works under bash 3.2, avoids `eval`
- [ ] Config reads the shared `.mario-skills/.env`, parsed not sourced
- [ ] Unknown keys in the shared `.env` are ignored, not fatal
- [ ] Ships `--config-info` reporting each value's source layer
- [ ] Missing-config errors list every location searched
- [ ] `SKILL.md` forbids the agent from reading or echoing `.env` values
- [ ] Writes back up before mutating a user file
- [ ] Emits a machine-readable JSON receipt on stdout
- [ ] `README.md` documents limitations honestly
- [ ] Both root READMEs updated
- [ ] `CHANGELOG.md` entry written
