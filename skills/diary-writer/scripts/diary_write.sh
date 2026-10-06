#!/bin/bash
#
# diary_write.sh — portable append-only diary writer for Obsidian vaults
#
# First run:
#   bash scripts/diary_write.sh --init
#
# Daily use (LLM / shell):
#   printf '%s' "今天的日记内容" | bash scripts/diary_write.sh
#
# Config resolution — highest priority first:
#   1. process environment            VAULT_DIR=... bash diary_write.sh
#   2. <cwd>/.mario-skills/.env       project-level, shared by all mario skills
#   3. ~/.mario-skills/.env          user-level, shared by all mario skills
#   4. diary-writer config.ini        $DIARY_CONFIG, else $XDG_CONFIG_HOME, else ~/.config
#   5. built-in defaults
#
# .mario-skills/.env is the marketplace-wide convention — sibling skill
# directories read these same two files, so a key is written once.
#
# All paths are configurable. Run --init once, then the script is portable.

set -uo pipefail

VERSION="1.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE_FILE="$SKILL_DIR/templates/diary-template.md"

# === XDG-aware defaults (overridable by config) ===
DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/diary-obsidian"
DEFAULT_CONFIG_PATH="$DEFAULT_CONFIG_DIR/config.ini"
DEFAULT_STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/diary-obsidian"
DEFAULT_VAULT_DIR="$HOME/Documents/Obsidian"
DEFAULT_JOURNALS_SUBDIR="journals"
DEFAULT_TEMPLATE_TAGS="日记,复盘"

CONFIG_PATH="${DIARY_CONFIG:-$DEFAULT_CONFIG_PATH}"

# === Shared .env files (the mario-skills convention) ===
# Overridable so tests and unusual layouts can relocate them.
ENV_HOME_FILE="${MARIO_SKILLS_ENV:-$HOME/.mario-skills/.env}"
ENV_PROJECT_FILE="${MARIO_SKILLS_PROJECT_ENV:-$PWD/.mario-skills/.env}"

# Snapshot the inherited process environment before anything reassigns these
# names, so the process.env layer of the chain stays readable after the
# resolved values land back in VAULT_DIR / STATE_DIR / etc.
SNAP_VAULT_DIR="${VAULT_DIR-}"
SNAP_JOURNALS_SUBDIR="${JOURNALS_SUBDIR-}"
SNAP_STATE_DIR="${STATE_DIR-}"
SNAP_TEMPLATE_TAGS="${TEMPLATE_TAGS-}"

# ============================================================
# Subcommands
# ============================================================

print_help() {
  cat <<EOF
diary_write.sh v$VERSION — portable diary writer

Usage:
  printf '%s' "entry" | bash diary_write.sh          # append to today's journal
  bash diary_write.sh --init                         # first-run setup wizard
  bash diary_write.sh --init --env                   # wizard writes the shared .mario-skills/.env
  bash diary_write.sh --init --dry-run               # preview init, no files written
  bash diary_write.sh --detect                       # list Obsidian vaults from app config
  bash diary_write.sh --config-info                  # show resolved config and where each value came from
  bash diary_write.sh --config-info --json           # same, machine-readable
  bash diary_write.sh --config PATH                  # override config.ini location
  bash diary_write.sh --help                         # this help
  bash diary_write.sh --version                      # print version

Flags:
  --init         run the first-run setup wizard (interactive)
  --env          with --init: write into the shared ~/.mario-skills/.env
                 instead of diary-writer's own config.ini. Existing keys in
                 that file are preserved; only diary-writer's four are updated.
  --dry-run      with --init: walk the wizard, print what would change,
                 write nothing, create no directories
  --detect       list vaults found in Obsidian's config (no writes)
  --config-info  print resolved values plus the source of each, and whether
                 each search location exists
  --config PATH  use PATH instead of the default config.ini location

Output (stdout): JSON { ok, action, path, duplicate, backup }

Config priority (highest first):
  1. process environment         VAULT_DIR=/path bash diary_write.sh
  2. <cwd>/.mario-skills/.env     project-level, shared by all mario skills
  3. ~/.mario-skills/.env        user-level, shared by all mario skills
  4. \$DIARY_CONFIG, else \$XDG_CONFIG_HOME/diary-obsidian/config.ini,
     else ~/.config/diary-obsidian/config.ini
  5. built-in defaults

Keys (VAULT_DIR, JOURNALS_SUBDIR, STATE_DIR, TEMPLATE_TAGS) are spelled the
same in every layer, so a config.ini can be moved into .mario-skills/.env
as-is. The .env files are parsed, never sourced, and are not committed.

State dir (hashes, logs, backups):
  \$XDG_DATA_HOME/diary-obsidian  →  ~/.local/share/diary-obsidian
EOF
}

# Returns 0 if any obsidian config found, paths one per line on success.
# Returns 1 if no obsidian.json found in any known location.
detect_obsidian_vaults() {
  local json
  for json in \
    "$HOME/Library/Application Support/obsidian/obsidian.json" \
    "$HOME/.config/obsidian/obsidian.json" \
    "${APPDATA:-}/obsidian/obsidian.json"; do
    [ -f "$json" ] || continue
    # Parse without jq (not always installed). The obsidian.json format is:
    #   { "vaults": { "<hash>": { "path": "...", "open": true/false } } }
    # We only need the path values; the only "path" keys in this file are
    # vault paths, so a flat grep is reliable here.
    grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$json" \
      | sed -E 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
    return 0
  done
  return 1
}

cmd_detect() {
  local json=""
  for j in \
    "$HOME/Library/Application Support/obsidian/obsidian.json" \
    "$HOME/.config/obsidian/obsidian.json" \
    "${APPDATA:-}/obsidian/obsidian.json"; do
    [ -f "$j" ] && { json="$j"; break; }
  done

  if [ -z "$json" ]; then
    echo "❌ No Obsidian config found in any of these locations:"
    echo "  macOS:   ~/Library/Application Support/obsidian/obsidian.json"
    echo "  Linux:   ~/.config/obsidian/obsidian.json"
    echo "  Windows: %APPDATA%/obsidian/obsidian.json"
    echo ""
    echo "If Obsidian is installed but vaults aren't listed, open Obsidian"
    echo "and add a vault first — then re-run --detect."
    return 0
  fi

  echo "📂 Obsidian vaults found in $json:"
  echo ""

  # Capture detected paths via temp file so the script stays POSIX-shell
  # portable. Process substitution `<()` is a bash-ism that fails under
  # `/bin/sh` (POSIX mode on macOS).
  local TMP_DETECT=$(mktemp -t "diary-detect-XXXXXX")
  detect_obsidian_vaults > "$TMP_DETECT" 2>/dev/null || true

  local count=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    count=$((count + 1))
    if [ -d "$path" ]; then
      echo "  [$count] ✓ $path"
    else
      echo "  [$count] ✗ (missing) $path"
    fi
  done < "$TMP_DETECT"
  rm -f "$TMP_DETECT"

  echo ""
  if [ "$count" -eq 0 ]; then
    echo "(Obsidian config exists but contains no vaults.)"
    echo "Open Obsidian → Open folder as vault → pick a directory."
  else
    echo "Total: $count vault(s). These are offered as defaults when you run --init."
  fi
}

cmd_init() {
  local dry_run="${1:-false}"
  local target="${2:-ini}"

  # Set up readline via a temp INPUTRC so case-insensitive path completion
  # actually takes effect inside `read -e`.
  #
  # Why INPUTRC and not `bind`? Bash's `bind` builtin in non-interactive
  # script context logs "未启用行编辑" and the readline state isn't fully
  # activated — variables get set in `bind -V` output but `read -e` doesn't
  # honor them. Setting INPUTRC env var causes readline to load the file at
  # its init time (which happens on the first `read -e`), bypassing the
  # bind limitations.
  #
  # Why `complete` instead of `complete-filename`? `complete` is bash/readline's
  # default smart completion (does filename when path-like, command when
  # command-like), and it's what interactive bash uses by default — we want
  # the same code path so completion-ignore-case is honored the same way.
  if [ -n "${BASH_VERSION:-}" ]; then
    DIARY_TMP_INPUTRC=$(mktemp -t "diary-inputrc-XXXXXX")
    {
      echo "set disable-completion off"
      echo "set completion-ignore-case on"
      echo "set show-all-if-ambiguous on"
      echo "TAB: complete"
    } > "$DIARY_TMP_INPUTRC"
    INPUTRC="$DIARY_TMP_INPUTRC"
    export INPUTRC
    trap 'rm -f "$DIARY_TMP_INPUTRC"' RETURN
  fi

  local INIT_DEST="$CONFIG_PATH"
  if [ "$target" = "env" ]; then
    INIT_DEST="$ENV_HOME_FILE"
  fi

  # Pre-fill the wizard from whatever is currently resolved, so re-running
  # --init shows the live values instead of built-in defaults.
  resolve_all_settings
  DEFAULT_VAULT_DIR="$VAULT_DIR"
  DEFAULT_JOURNALS_SUBDIR="$JOURNALS_SUBDIR"
  DEFAULT_STATE_DIR="$STATE_DIR"
  DEFAULT_TEMPLATE_TAGS="$TEMPLATE_TAGS"

  echo "🎯 diary-writer first-run setup"
  if [ "$dry_run" = "true" ]; then
    echo "⚠️  DRY-RUN — no files will be written, no directories will be created"
  fi
  if [ "$target" = "env" ]; then
    echo "📄 Target: shared $INIT_DEST (read by every mario-skills skill)"
  else
    echo "📄 Target: $INIT_DEST (diary-writer only)"
    echo "   Use --init --env to write into the shared .mario-skills/.env instead."
  fi
  echo ""
  echo "Config will be saved to: $INIT_DEST"
  echo "Press Enter to accept defaults in [brackets]."
  echo ""

  # Vault directory — try to auto-detect from Obsidian's app config.
  # Capture via temp file (POSIX-portable, works under /bin/sh too).
  local -a DETECTED_VAULTS=()
  local TMP_DETECT=$(mktemp -t "diary-detect-XXXXXX")
  detect_obsidian_vaults > "$TMP_DETECT" 2>/dev/null || true
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    DETECTED_VAULTS+=("$path")
  done < "$TMP_DETECT"
  rm -f "$TMP_DETECT"

  local VAULT_PROMPT VAULT_DEFAULT
  if [ "${#DETECTED_VAULTS[@]}" -eq 0 ]; then
    # No detection — fall back to the static default
    VAULT_DEFAULT="$DEFAULT_VAULT_DIR"
    VAULT_PROMPT="Vault directory [$VAULT_DEFAULT]"
  elif [ "${#DETECTED_VAULTS[@]}" -eq 1 ]; then
    # Exactly one vault detected — use silently as default
    VAULT_DEFAULT="${DETECTED_VAULTS[0]}"
    VAULT_PROMPT="Vault directory [$VAULT_DEFAULT] (auto-detected from Obsidian)"
  else
    # Multiple vaults — list, let user pick by number or type a path
    echo "Multiple Obsidian vaults detected:"
    local i
    for i in "${!DETECTED_VAULTS[@]}"; do
      if [ -d "${DETECTED_VAULTS[$i]}" ]; then
        echo "  [$((i+1))] ✓ ${DETECTED_VAULTS[$i]}"
      else
        echo "  [$((i+1))] ✗ ${DETECTED_VAULTS[$i]}"
      fi
    done
    echo ""
    VAULT_DEFAULT="${DETECTED_VAULTS[0]}"
    VAULT_PROMPT="Vault directory (1-${#DETECTED_VAULTS[@]} or path) [$VAULT_DEFAULT]"
  fi

  read -e -r -p "$VAULT_PROMPT: " input
  input="${input:-$VAULT_DEFAULT}"
  # Unescape backslash-space sequences. When entering paths interactively users
  # sometimes escape them thinking it's shell syntax (e.g. "Mobile\ Documents"),
  # but `read` keeps the literal characters — which the filesystem doesn't have.
  # Stripping just "\ " → " " is targeted enough to fix the common mistake
  # without altering paths that legitimately contain backslashes.
  input="${input//\\ / }"

  # If user typed a number within range, resolve to the corresponding vault.
  if [[ "$input" =~ ^[0-9]+$ ]] \
     && [ "$input" -ge 1 ] \
     && [ "$input" -le "${#DETECTED_VAULTS[@]}" ]; then
    VAULT_DIR="${DETECTED_VAULTS[$((input-1))]}"
  else
    VAULT_DIR="$input"
  fi
  VAULT_DIR="${VAULT_DIR/#\~/$HOME}"

  if [ ! -d "$VAULT_DIR" ]; then
    echo "❌ Vault directory does not exist: $VAULT_DIR"
    exit 1
  fi

  # Journals subdir
  read -e -r -p "Journals subdir, relative to vault [$DEFAULT_JOURNALS_SUBDIR]: " input
  JOURNALS_SUBDIR="${input:-$DEFAULT_JOURNALS_SUBDIR}"
  JOURNALS_SUBDIR="${JOURNALS_SUBDIR//\\ / }"

  JOURNALS_DIR="${VAULT_DIR}/${JOURNALS_SUBDIR}"
  # Echo the resolved full path so the user can verify what they ended up with.
  echo "📂 Journals directory: $JOURNALS_DIR"
  if [ ! -d "$JOURNALS_DIR" ]; then
    if [ "$dry_run" = "true" ]; then
      echo "📝 Would create directory: $JOURNALS_DIR"
    else
      read -e -r -p "Subdir doesn't exist. Create it? [y/N]: " CREATE
      if [[ "$CREATE" =~ ^[Yy]$ ]]; then
        mkdir -p "$JOURNALS_DIR"
        echo "✅ Created $JOURNALS_DIR"
      else
        echo "❌ Refusing to write into a non-existent journals dir."
        exit 1
      fi
    fi
  fi

  # State directory
  read -e -r -p "State directory, hashes/logs/backups [$DEFAULT_STATE_DIR]: " input
  STATE_DIR="${input:-$DEFAULT_STATE_DIR}"
  STATE_DIR="${STATE_DIR//\\ / }"
  STATE_DIR="${STATE_DIR/#\~/$HOME}"
  echo "📂 State directory: $STATE_DIR"

  # Tags (blank = no default tags)
  read -e -r -p "Default tags, comma-separated, blank for none [$DEFAULT_TEMPLATE_TAGS]: " input
  TEMPLATE_TAGS="${input:-$DEFAULT_TEMPLATE_TAGS}"

  # Compose the config content into a string, decide at the end whether to persist
  local CONFIG_CONTENT
  CONFIG_CONTENT="# diary-writer config
# Generated by --init on $(date "+%Y-%m-%d %H:%M:%S")
VAULT_DIR=$VAULT_DIR
JOURNALS_SUBDIR=$JOURNALS_SUBDIR
STATE_DIR=$STATE_DIR
TEMPLATE_TAGS=$TEMPLATE_TAGS"

  if [ "$dry_run" = "true" ]; then
    echo ""
    echo "📝 Would write the following to $INIT_DEST:"
    echo "---"
    printf '%s\n' "$CONFIG_CONTENT"
    echo "---"
    echo ""
    if [ "$target" = "env" ] && [ -f "$INIT_DEST" ]; then
      echo "⚠️  $INIT_DEST already exists. Existing keys not listed above are preserved."
    fi
    echo "Nothing was changed. Re-run without --dry-run to apply."
    return 0
  fi

  mkdir -p "$(dirname "$INIT_DEST")"

  if [ "$target" = "env" ] && [ -f "$INIT_DEST" ]; then
    # Merge, never truncate: the file is shared, so another skill's keys and
    # the user's own comments must survive a diary-writer re-init.
    local MERGED
    MERGED=$(mktemp -t "diary-env-merge-XXXXXX")
    local k newval
    for k in VAULT_DIR JOURNALS_SUBDIR STATE_DIR TEMPLATE_TAGS; do
      case "$k" in
        VAULT_DIR)       newval="$VAULT_DIR" ;;
        JOURNALS_SUBDIR) newval="$JOURNALS_SUBDIR" ;;
        STATE_DIR)       newval="$STATE_DIR" ;;
        TEMPLATE_TAGS)   newval="$TEMPLATE_TAGS" ;;
      esac
      if grep -qE "^[[:space:]]*(export[[:space:]]+)?${k}[[:space:]]*=" "$INIT_DEST"; then
        sed -E "s|^([[:space:]]*(export[[:space:]]+)?)${k}[[:space:]]*=.*$|${k}=${newval}|" \
          "$INIT_DEST" > "$MERGED"
      else
        cp "$INIT_DEST" "$MERGED"
        printf '%s=%s\n' "$k" "$newval" >> "$MERGED"
      fi
      cp "$MERGED" "$INIT_DEST"
    done
    rm -f "$MERGED"
  else
    printf '%s\n' "$CONFIG_CONTENT" > "$INIT_DEST"
  fi

  echo ""
  echo "✅ Config written to $INIT_DEST"
  if [ "$target" = "env" ]; then
    echo "   Every mario-skills skill reads this file. Keep it out of git."
  fi
  echo ""
  echo "Smoke test:"
  echo "  printf '%s' \"hello diary\" | bash $SCRIPT_DIR/diary_write.sh"
  echo ""
  echo "(It will create ${VAULT_DIR}/${JOURNALS_SUBDIR}/$(date "+%Y-%m-%d").md if today is empty.)"
}

# ============================================================
# Config loader
# ============================================================

# Prints KEY's value from a dotenv-style KEY=VALUE file. Last definition
# wins, matching dotenv. Parses rather than `source`s the file: sourcing
# would execute whatever is in it.
env_get() {
  local want="$1" file="$2" line key val found=""
  [ -n "$file" ] && [ -f "$file" ] || return 1
  [ -r "$file" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      export[[:space:]]*) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac

    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
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

# Same file grammar as env_get; the two layers stay byte-compatible so a
# config.ini can be moved into .mario-skills/.env without edits.
ini_get() { env_get "$1" "$2"; }

# Walks the priority chain for KEY and records which layer answered.
# CURRENT is this process's inherited value for that key, snapshotted at
# startup — resolve_setting must not read the variables it writes, or a
# second call would treat the first call's result as process.env.
# Sets RESOLVED_<KEY> and SOURCE_<KEY>.
resolve_setting() {
  local key="$1" current="$2" default="$3"
  local val="" src=""

  if [ -n "$current" ]; then
    val="$current"
    src="process.env"
  elif val="$(env_get "$key" "$ENV_PROJECT_FILE")"; then
    src="<cwd>/.mario-skills/.env"
  elif val="$(env_get "$key" "$ENV_HOME_FILE")"; then
    src="~/.mario-skills/.env"
  elif val="$(ini_get "$key" "$CONFIG_PATH")"; then
    src="$CONFIG_PATH"
  else
    val="$default"
    src="built-in default"
  fi

  printf -v "RESOLVED_$key" '%s' "$val"
  printf -v "SOURCE_$key"   '%s' "$src"
}

resolve_all_settings() {
  resolve_setting VAULT_DIR       "$SNAP_VAULT_DIR"       "$DEFAULT_VAULT_DIR"
  resolve_setting JOURNALS_SUBDIR "$SNAP_JOURNALS_SUBDIR" "$DEFAULT_JOURNALS_SUBDIR"
  resolve_setting STATE_DIR       "$SNAP_STATE_DIR"       "$DEFAULT_STATE_DIR"
  resolve_setting TEMPLATE_TAGS   "$SNAP_TEMPLATE_TAGS"   "$DEFAULT_TEMPLATE_TAGS"

  VAULT_DIR="${RESOLVED_VAULT_DIR/#\~/$HOME}"
  JOURNALS_SUBDIR="$RESOLVED_JOURNALS_SUBDIR"
  STATE_DIR="${RESOLVED_STATE_DIR/#\~/$HOME}"
  TEMPLATE_TAGS="$RESOLVED_TEMPLATE_TAGS"
}

load_config() {
  resolve_all_settings

  if [ "$SOURCE_VAULT_DIR" = "built-in default" ]; then
    printf '{"ok":false,"error":"config_not_found","searched":['
    first=1
    while IFS= read -r sp; do
      [ $first -eq 1 ] || printf ','
      printf '"%s"' "$sp"
      first=0
    done <<EOF
process.env
$ENV_PROJECT_FILE
$ENV_HOME_FILE
$CONFIG_PATH
EOF
    printf '],"hint":"run: bash diary_write.sh --init"}\n'
    return 1
  fi

  JOURNALS_DIR="${VAULT_DIR}/${JOURNALS_SUBDIR}"
  HASH_DIR="${STATE_DIR}/hashes"
  LOG_DIR="${STATE_DIR}/logs"
  BACKUP_DIR="${STATE_DIR}/backups"

  mkdir -p "$HASH_DIR" "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null
  return 0
}

cmd_config_info() {
  if ! load_config; then
    return 1
  fi

  if [ "${1:-}" = "--json" ]; then
    printf '{"ok":true,"settings":{'
    printf '"VAULT_DIR":{"value":"%s","source":"%s"},'       "$VAULT_DIR"       "$SOURCE_VAULT_DIR"
    printf '"JOURNALS_SUBDIR":{"value":"%s","source":"%s"},' "$JOURNALS_SUBDIR" "$SOURCE_JOURNALS_SUBDIR"
    printf '"STATE_DIR":{"value":"%s","source":"%s"},'       "$STATE_DIR"       "$SOURCE_STATE_DIR"
    printf '"TEMPLATE_TAGS":{"value":"%s","source":"%s"}'    "$TEMPLATE_TAGS"   "$SOURCE_TEMPLATE_TAGS"
    printf '},"searched":['
    first=1
    for sp in "process.env" "$ENV_PROJECT_FILE" "$ENV_HOME_FILE" "$CONFIG_PATH"; do
      [ $first -eq 1 ] || printf ','
      if [ -f "$sp" ]; then mark="found"; else mark="absent"; fi
      printf '{"path":"%s","%s":"%s"}' "$sp" "$([ "$sp" = "process.env" ] && echo env || echo file)" "$mark"
      first=0
    done
    printf ']}\n'
    return 0
  fi

  echo "diary_write.sh v$VERSION — resolved config"
  echo ""
  printf '  %-16s %s\n' "VAULT_DIR" "$VAULT_DIR"
  printf '  %-16s %s\n' "JOURNALS_SUBDIR" "$JOURNALS_SUBDIR"
  printf '  %-16s %s\n' "STATE_DIR" "$STATE_DIR"
  printf '  %-16s %s\n' "TEMPLATE_TAGS" "${TEMPLATE_TAGS:-(none)}"
  echo ""
  echo "Sources (highest priority first):"
  printf '  %-16s %s\n' "VAULT_DIR"       "$SOURCE_VAULT_DIR"
  printf '  %-16s %s\n' "JOURNALS_SUBDIR" "$SOURCE_JOURNALS_SUBDIR"
  printf '  %-16s %s\n' "STATE_DIR"       "$SOURCE_STATE_DIR"
  printf '  %-16s %s\n' "TEMPLATE_TAGS"   "$SOURCE_TEMPLATE_TAGS"
  echo ""
  echo "Search path:"
  printf '  %-4s %s\n' "[1]" "process.env"
  printf '  %-4s %s\n' "[2]" "$ENV_PROJECT_FILE$([ -f "$ENV_PROJECT_FILE" ] && echo '  (found)')"
  printf '  %-4s %s\n' "[3]" "$ENV_HOME_FILE$([ -f "$ENV_HOME_FILE" ] && echo '  (found)')"
  printf '  %-4s %s\n' "[4]" "$CONFIG_PATH$([ -f "$CONFIG_PATH" ] && echo '  (found)')"
  echo ""
  echo "Journals directory: $JOURNALS_DIR"
  [ -d "$JOURNALS_DIR" ] && echo "  ✓ exists" || echo "  ✗ missing — create it or re-run --init"
}

# ============================================================
# Argument parsing
# ============================================================

INIT_REQUESTED="false"
DRY_RUN="false"
INIT_TARGET="ini"
CONFIG_INFO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)
      INIT_REQUESTED="true"
      shift
      ;;
    --detect)
      cmd_detect
      exit 0
      ;;
    --config-info)
      CONFIG_INFO="text"
      shift
      if [[ "${1:-}" == "--json" ]]; then
        CONFIG_INFO="json"
        shift
      fi
      ;;
    --env)
      INIT_TARGET="env"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    --version|-V)
      echo "Version: $VERSION"
      exit 0
      ;;
    --config)
      if [[ $# -lt 2 ]]; then
        echo "❌ --config requires a path argument" >&2
        exit 1
      fi
      CONFIG_PATH="$2"
      shift 2
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 1
      ;;
  esac
done

if [ "$INIT_REQUESTED" = "true" ]; then
  cmd_init "$DRY_RUN" "$INIT_TARGET"
  exit 0
fi

if [ "$CONFIG_INFO" = "json" ]; then
  cmd_config_info --json
  exit 0
fi

if [ "$CONFIG_INFO" = "text" ]; then
  cmd_config_info
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "❌ --dry-run is only meaningful with --init" >&2
  exit 1
fi

# ============================================================
# Main
# ============================================================

if ! load_config; then
  exit 1
fi

if [ ! -d "$JOURNALS_DIR" ]; then
  printf '{"ok":false,"error":"journals_dir_not_found","path":"%s","hint":"create it or re-run --init"}\n' "$JOURNALS_DIR"
  exit 1
fi

# === Date constants ===
TODAY=$(date "+%Y-%m-%d")
NOW=$(date "+%H:%M:%S")
WEEK=$(date "+%V")
WEEKDAY_NUM=$(date "+%u")
case "$WEEKDAY_NUM" in
  1) WEEKDAY_CN="一" ;; 2) WEEKDAY_CN="二" ;; 3) WEEKDAY_CN="三" ;;
  4) WEEKDAY_CN="四" ;; 5) WEEKDAY_CN="五" ;; 6) WEEKDAY_CN="六" ;;
  7) WEEKDAY_CN="日" ;;
  *) WEEKDAY_CN="?" ;;
esac

JOURNAL_FILE="${JOURNALS_DIR}/${TODAY}.md"
HASH_FILE="${HASH_DIR}/${TODAY}.hash"
TMP_DRAFT=$(mktemp -t "diary-draft-XXXXXX.md")
TMP_ERR=$(mktemp -t "diary-err-XXXXXX.log")

cleanup() {
  rm -f "$TMP_DRAFT" "$TMP_ERR" 2>/dev/null || true
}
trap cleanup EXIT

# === Read stdin ===
USER_CONTENT=""
while IFS= read -r line || [ -n "$line" ]; do
  USER_CONTENT="${USER_CONTENT}${line}"$'\n'
done
USER_CONTENT="${USER_CONTENT%$'\n'}"

if [ -z "$USER_CONTENT" ]; then
  printf '{"ok":false,"error":"empty_content"}\n'
  exit 1
fi

# === Light cleanup (Chinese-specific normalization) ===
# These rules are intentionally narrow — they only fix obvious AI-style padding
# and accidental key-stroke repeats. They do NOT rewrite meaning.
CLEANED=$(printf '%s' "$USER_CONTENT" | \
  sed 's/作为一[名个]//g' | \
  sed 's/在当今时代[，,]//g' | \
  sed 's/总而言之[，,]//g' | \
  sed 's/我我我/我/g' | \
  sed 's/的的的/的/g' | \
  sed 's/。。/。/g' | \
  sed 's/，，/，/g' | \
  sed 's/  */ /g')

# === MD5 dedup ===
HASH=$(printf '%s' "$CLEANED" | md5sum | cut -d' ' -f1)
touch "$HASH_FILE"
DUP="false"
if grep -qxF "$HASH" "$HASH_FILE" 2>/dev/null; then
  DUP="true"
fi

if [ "$DUP" = "true" ]; then
  printf '{"ok":true,"action":"skip_duplicate","path":"%s/%s.md","duplicate":true,"note":"hash_already_in_%s.hash"}\n' \
    "$JOURNALS_SUBDIR" "$TODAY" "$TODAY"
  exit 0
fi

# === Build frontmatter in shell (template is body-only) ===
TAGS_YAML=""
if [ -n "$TEMPLATE_TAGS" ]; then
  IFS=',' read -ra TAG_ARR <<< "$TEMPLATE_TAGS"
  for tag in "${TAG_ARR[@]}"; do
    tag="$(echo "$tag" | xargs)"
    [ -n "$tag" ] && TAGS_YAML="${TAGS_YAML}
  - ${tag}"
  done
fi

FRONTMATTER="---
date: ${TODAY}
week: ${WEEK}
tags:${TAGS_YAML}
---"

TITLE="# 📅 ${TODAY} 星期${WEEKDAY_CN}"

# === Render template (delete any <%* ... _%> multi-line blocks, keep inline) ===
if [ ! -f "$TEMPLATE_FILE" ]; then
  printf '{"ok":false,"error":"template_not_found","template":"%s"}\n' "$TEMPLATE_FILE"
  exit 1
fi

BODY=$(awk '
  BEGIN { skip = 0 }
    /<%\*/ { skip = 1; next }
    /_%>/  { if (skip) { skip = 0; next } }
  skip { next }
  { print }
' "$TEMPLATE_FILE")

# ============================================================
# Branch 1: file does not exist → create
# ============================================================
if [ ! -f "$JOURNAL_FILE" ]; then
  FINAL="${FRONTMATTER}

${TITLE}

${BODY}
### 📍 ${TODAY} ${NOW}

${CLEANED}"

  printf '%s\n' "$FINAL" > "$TMP_DRAFT"

  # validate: non-empty + at least 2 frontmatter delimiters
  if [ ! -s "$TMP_DRAFT" ]; then
    printf '{"ok":false,"error":"empty_draft"}\n'
    exit 1
  fi
  FM_COUNT=$(head -10 "$TMP_DRAFT" | grep -c '^---$' || true)
  if [ "${FM_COUNT:-0}" -lt 2 ]; then
    printf '{"ok":false,"error":"frontmatter_incomplete","frontmatter_lines":%d}\n' "${FM_COUNT:-0}"
    exit 1
  fi

  # write via redirect (predictable, config-honoring, no Obsidian CLI assumption)
  if printf '%s\n' "$FINAL" > "$JOURNAL_FILE" 2>"$TMP_ERR"; then
    # only record dedup hash after file actually exists on disk
    if [ -s "$JOURNAL_FILE" ]; then
      echo "$HASH" >> "$HASH_FILE"
      BYTES=$(wc -c < "$JOURNAL_FILE" 2>/dev/null | tr -d ' ' || echo 0)
      printf '{"ok":true,"action":"create","path":"%s/%s.md","duplicate":%s,"bytes":%s}\n' \
        "$JOURNALS_SUBDIR" "$TODAY" "$DUP" "$BYTES"
      exit 0
    fi
  fi

  printf '{"ok":false,"error":"write_failed","path":"%s"}\n' "$JOURNAL_FILE"
  cat "$TMP_ERR" >&2
  exit 1
fi

# ============================================================
# Branch 2: file exists → backup → append
# ============================================================
BACKUP_FILE="${BACKUP_DIR}/diary-backup-${TODAY}-$(date +%H%M%S).md"
cp "$JOURNAL_FILE" "$BACKUP_FILE" 2>/dev/null || BACKUP_FILE=""

APPEND_BLOCK="
### 📍 ${TODAY} ${NOW}

${CLEANED}"

printf '%s\n' "$APPEND_BLOCK" > "$TMP_DRAFT"

# append via redirect (predictable, config-honoring)
if printf '%s\n' "$APPEND_BLOCK" >> "$JOURNAL_FILE" 2>"$TMP_ERR"; then
  if [ -s "$JOURNAL_FILE" ]; then
    FM_POST=$(grep -c '^---$' "$JOURNAL_FILE" | head -1 || echo 0)
    if [ "${FM_POST:-0}" -ge 2 ]; then
      echo "$HASH" >> "$HASH_FILE"
      printf '{"ok":true,"action":"append","path":"%s/%s.md","duplicate":%s,"backup":"%s"}\n' \
        "$JOURNALS_SUBDIR" "$TODAY" "$DUP" "$BACKUP_FILE"
      exit 0
    fi
  fi
  # post-write validation failed → restore backup
  [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$JOURNAL_FILE"
  printf '{"ok":false,"error":"post_write_validation_failed_rolled_back","backup":"%s"}\n' "$BACKUP_FILE"
  exit 1
fi

# append failed → restore and bail
[ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$JOURNAL_FILE"
printf '{"ok":false,"error":"append_write_failed","path":"%s"}\n' "$JOURNAL_FILE"
cat "$TMP_ERR" >&2
exit 1