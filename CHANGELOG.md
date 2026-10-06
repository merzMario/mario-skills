# Changelog

All notable changes to this marketplace. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [semver](https://semver.org/spec/v2.0.0.html).

The version here is the single source of truth — it lives in `metadata.version` in
`.claude-plugin/marketplace.json` and is what users receive on marketplace update.

## 0.1.0 - 2026-10-07

### Features
- `mario-skills`: marketplace scaffold — single-plugin manifest, bilingual README, author guide, and a validator that fails when a skill directory is not registered
- Shared `.env` convention: every skill reads `<project>/.mario-skills/.env` and `~/.mario-skills/.env`, so a key is written once and all skills see it. Values are parsed, never `source`d, so a credentials file cannot execute code. Both locations gitignored
- `diary-writer`: read the shared `.env` for `VAULT_DIR` / `JOURNALS_SUBDIR` / `STATE_DIR` / `TEMPLATE_TAGS`, resolved per key through process env → project `.env` → user `.env` → `config.ini` → built-in defaults. Existing `config.ini` setups keep working unchanged
- `diary-writer`: `--config-info` (`--json` for machine use) reports each resolved value plus the layer that supplied it and whether each search location exists — one command replaces guessing when the vault looks wrong
- `diary-writer`: missing-config errors now enumerate every location searched in a `searched` array
- `diary-writer`: `--init --env` writes into the shared `~/.mario-skills/.env`, merging per key so other skills' entries and the user's own comments survive a re-init
- `diary-writer`: `--init` pre-fills the wizard from currently resolved values, so re-running it shows your live config instead of built-in defaults

### Fixes
- `diary-writer`: values in the config parser are trimmed without collapsing internal whitespace, so paths containing spaces (e.g. `Mobile Documents`) round-trip unchanged
