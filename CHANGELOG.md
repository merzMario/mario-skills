# Changelog

All notable changes to this marketplace. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [semver](https://semver.org/spec/v2.0.0.html).

The version here is the single source of truth — it lives in `metadata.version` in
`.claude-plugin/marketplace.json` and is what users receive on marketplace update.

## 0.2.0 - 2026-10-08

### Breaking changes
- `diary-writer`: `~/.config/diary-obsidian/config.ini` is no longer read. `.mario-skills/.env` is now the single config file for every skill, so configuration no longer spans two formats. Migrate by moving the file — both grammars are identical, so no key needs renaming:
  ```bash
  mkdir -p ~/.mario-skills
  mv ~/.config/diary-obsidian/config.ini ~/.mario-skills/.env
  ```
- `diary-writer`: `--config PATH` removed — it only ever pointed at a `config.ini`. It now exits with a message pointing at `--config-info`.
- `diary-writer`: `--init --env` removed. With one config surface the flag was redundant; `--init` writes `~/.mario-skills/.env` and the new `--init --project` writes `<cwd>/.mario-skills/.env`.

### Features
- `diary-writer`: `--init --project` writes the project-level `.env`, for a single vault scoped to one directory
- `diary-writer`: resolution chain is now process env → project `.env` → user `.env` → built-in defaults
- `mario-skills`: `examples/env.shared.example` documents the shared file; the per-skill `config.minimal.ini` / `config.full.ini` examples are gone

### Fixes
- `diary-writer`: values are trimmed without collapsing internal whitespace, so paths containing spaces (e.g. `Mobile Documents`) round-trip unchanged

## 0.1.0 - 2026-10-07

### Features
- `mario-skills`: marketplace scaffold — single-plugin manifest, bilingual README, author guide, and a validator that fails when a skill directory is not registered
- Shared `.env` convention: every skill reads `<project>/.mario-skills/.env` and `~/.mario-skills/.env`, so a key is written once and all skills see it. Values are parsed, never `source`d, so a credentials file cannot execute code. Both locations gitignored
- `diary-writer`: append-only journal writer for local markdown vaults. ISO week numbering, MD5 dedup, pre-write backups, JSON receipts on stdout
- `diary-writer`: `--config-info` (`--json` for machine use) reports each resolved value plus the layer that supplied it and whether each search location exists — one command replaces guessing when the vault looks wrong
- `diary-writer`: missing-config errors enumerate every location searched in a `searched` array
- `diary-writer`: `--init` pre-fills the wizard from currently resolved values, so re-running it shows your live config instead of built-in defaults
