#!/bin/bash
# book_env.sh — shared .env resolution for book-enquire-reader.
#
# Sourced, never executed. Provides:
#   env_get KEY FILE      read one KEY=VALUE from a dotenv file
#   book_load_config      walk the priority chain, assign the resolved values
#   book_config_info      print resolved values plus the layer that supplied each
#
# `.mario-skills/.env` is the only config file, marketplace-wide. Sibling skills
# read the same two files, so a key is written once and every skill sees it.
# Keys this skill does not recognize are ignored — that is what lets one file
# serve every skill.
#
# Resolution order, highest priority first:
#   1. process environment          VAULT_DIR=/x bash book_import.sh
#   2. <cwd>/.mario-skills/.env     project-level
#   3. ~/.mario-skills/.env        user-level
#   4. built-in defaults
#
# Values are PARSED, never `source`d. A .env may contain `$(...)` or `;`;
# sourcing it would hand arbitrary code execution to a credentials file.

# Overridable so tests and unusual layouts can relocate the two files.
BOOK_ENV_HOME_FILE="${MARIO_SKILLS_ENV:-$HOME/.mario-skills/.env}"
BOOK_ENV_PROJECT_FILE="${MARIO_SKILLS_PROJECT_ENV:-$PWD/.mario-skills/.env}"

BOOK_DEFAULT_VAULT_DIR="$HOME/Documents/Obsidian"
BOOK_DEFAULT_BOOKS_SUBDIR="raw/books"
# The retrieval scope. Search is always confined to this folder so that the
# digests written next to it never enter the candidate pool.
BOOK_DEFAULT_SOURCE_SUBDIR="_source"
BOOK_DEFAULT_NOTES_SUBDIR="notes"
BOOK_DEFAULT_HYDE="true"
BOOK_DEFAULT_GRAPH="true"
BOOK_DEFAULT_OCR="false"
BOOK_DEFAULT_MAX_CHUNKS="5"
BOOK_DEFAULT_ENQUIRE_BIN="enquire-mcp"
BOOK_DEFAULT_STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/book-enquire-reader"
BOOK_DEFAULT_AUTO_INGEST="true"
BOOK_DEFAULT_AUTO_INGEST_MAX="1"

# Snapshot the inherited process environment before anything reassigns these
# names. resolve_setting reads the snapshot, never the live variable — otherwise
# a second call would mistake the first call's result for process.env.
BOOK_SNAP_VAULT_DIR="${VAULT_DIR-}"
BOOK_SNAP_BOOKS_SUBDIR="${BOOKS_SUBDIR-}"
BOOK_SNAP_SOURCE_SUBDIR="${BOOK_SOURCE_SUBDIR-}"
BOOK_SNAP_NOTES_SUBDIR="${BOOK_NOTES_SUBDIR-}"
BOOK_SNAP_HYDE="${BOOK_HYDE-}"
BOOK_SNAP_GRAPH="${BOOK_GRAPH-}"
BOOK_SNAP_OCR="${BOOK_OCR-}"
BOOK_SNAP_MAX_CHUNKS="${BOOK_MAX_CHUNKS-}"
BOOK_SNAP_ENQUIRE_BIN="${BOOK_ENQUIRE_BIN-}"
BOOK_SNAP_STATE_DIR="${BOOK_STATE_DIR-}"
BOOK_SNAP_AUTO_INGEST="${BOOK_AUTO_INGEST-}"
BOOK_SNAP_AUTO_INGEST_MAX="${BOOK_AUTO_INGEST_MAX-}"

# Prints KEY's value from a dotenv file; last definition wins. Returns 1 when
# the key is absent, so callers can chain layers with `elif val=$(...)`.
env_get() {
  local want="$1" file="$2" line key val found=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in export[[:space:]]*) line="${line#export }" ;; esac
    case "$line" in *=*) ;; *) continue ;; esac

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

# Walks the priority chain for KEY and records which layer answered.
#
# Records go into BOOK_RESOLVED_RECORDS rather than RESOLVED_<KEY> /
# SOURCE_<KEY> variables: reading those back would require indirect expansion,
# and dynamic variable lookup is exactly what this skill is better off without.
book_resolve_setting() {
  local key="$1" current="$2" default="$3"
  local val="" src=""

  if [ -n "$current" ]; then
    val="$current"
    src="process.env"
  elif val="$(env_get "$key" "$BOOK_ENV_PROJECT_FILE")"; then
    src="<cwd>/.mario-skills/.env"
  elif val="$(env_get "$key" "$BOOK_ENV_HOME_FILE")"; then
    src="~/.mario-skills/.env"
  else
    val="$default"
    src="built-in default"
  fi

  # CURRENT is the process.env snapshot passed in by the caller, never a
  # variable written here — reading one back would make the second call treat
  # the first call's result as process.env.
  BOOK_RESOLVED_RECORDS="${BOOK_RESOLVED_RECORDS}${key}"$'\t'"${val}"$'\t'"${src}"$'\n'
}

# Expands a leading ~ so paths can be written that way in the .env.
book_expand_tilde() {
  local v="$1"
  case "$v" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${v#\~/}" ;;
    *) printf '%s' "$v" ;;
  esac
}

# Resolves every key this skill owns, per key independently: setting only
# VAULT_DIR must not reset the other ten to defaults.
#
# Records are emitted in this order, and the --config-info renderers read them
# positionally:
#   VAULT_DIR BOOKS_SUBDIR BOOK_SOURCE_SUBDIR BOOK_NOTES_SUBDIR BOOK_HYDE
#   BOOK_GRAPH BOOK_OCR BOOK_MAX_CHUNKS BOOK_ENQUIRE_BIN BOOK_STATE_DIR
#   BOOK_AUTO_INGEST BOOK_AUTO_INGEST_MAX
book_resolve_all() {
  BOOK_RESOLVED_RECORDS=""

  book_resolve_setting VAULT_DIR         "$BOOK_SNAP_VAULT_DIR"     "$BOOK_DEFAULT_VAULT_DIR"
  book_resolve_setting BOOKS_SUBDIR     "$BOOK_SNAP_BOOKS_SUBDIR" "$BOOK_DEFAULT_BOOKS_SUBDIR"
  book_resolve_setting BOOK_SOURCE_SUBDIR "$BOOK_SNAP_SOURCE_SUBDIR" "$BOOK_DEFAULT_SOURCE_SUBDIR"
  book_resolve_setting BOOK_NOTES_SUBDIR "$BOOK_SNAP_NOTES_SUBDIR" "$BOOK_DEFAULT_NOTES_SUBDIR"
  book_resolve_setting BOOK_HYDE        "$BOOK_SNAP_HYDE"        "$BOOK_DEFAULT_HYDE"
  book_resolve_setting BOOK_GRAPH       "$BOOK_SNAP_GRAPH"       "$BOOK_DEFAULT_GRAPH"
  book_resolve_setting BOOK_OCR         "$BOOK_SNAP_OCR"         "$BOOK_DEFAULT_OCR"
  book_resolve_setting BOOK_MAX_CHUNKS  "$BOOK_SNAP_MAX_CHUNKS"  "$BOOK_DEFAULT_MAX_CHUNKS"
  book_resolve_setting BOOK_ENQUIRE_BIN "$BOOK_SNAP_ENQUIRE_BIN" "$BOOK_DEFAULT_ENQUIRE_BIN"
  book_resolve_setting BOOK_STATE_DIR   "$BOOK_SNAP_STATE_DIR"   "$BOOK_DEFAULT_STATE_DIR"
  book_resolve_setting BOOK_AUTO_INGEST "$BOOK_SNAP_AUTO_INGEST" "$BOOK_DEFAULT_AUTO_INGEST"
  book_resolve_setting BOOK_AUTO_INGEST_MAX "$BOOK_SNAP_AUTO_INGEST_MAX" "$BOOK_DEFAULT_AUTO_INGEST_MAX"

  # Second pass: pull the resolved values back out by position to assign the
  # plain variables the rest of the scripts read. Only the path keys get ~ expansion.
  local rec
  while IFS=$'\t' read -r rec_key rec rec_src; do
    case "$rec_key" in
      VAULT_DIR)
        VAULT_DIR="$(book_expand_tilde "$rec")"
        VAULT_DIR_SOURCE="$rec_src"
        ;;
      BOOK_STATE_DIR)  BOOK_STATE_DIR="$(book_expand_tilde "$rec")" ;;
      BOOKS_SUBDIR)     BOOKS_SUBDIR="$rec" ;;
      BOOK_SOURCE_SUBDIR) BOOK_SOURCE_SUBDIR="$rec" ;;
      BOOK_NOTES_SUBDIR) BOOK_NOTES_SUBDIR="$rec" ;;
      BOOK_HYDE)        BOOK_HYDE="$rec" ;;
      BOOK_GRAPH)       BOOK_GRAPH="$rec" ;;
      BOOK_OCR)         BOOK_OCR="$rec" ;;
      BOOK_MAX_CHUNKS)  BOOK_MAX_CHUNKS="$rec" ;;
      BOOK_ENQUIRE_BIN) BOOK_ENQUIRE_BIN="$rec" ;;
      BOOK_AUTO_INGEST) BOOK_AUTO_INGEST="$rec" ;;
      BOOK_AUTO_INGEST_MAX) BOOK_AUTO_INGEST_MAX="$rec" ;;
    esac
  done <<EOF
$BOOK_RESOLVED_RECORDS
EOF
}

# The JSON error a missing VAULT_DIR produces. It enumerates EVERY location
# searched so the agent can relay `searched` verbatim instead of paraphrasing.
book_config_not_found_json() {
  printf '{"ok":false,"error":"config_not_found","searched":['
  printf '"process.env","%s","%s"' "$BOOK_ENV_PROJECT_FILE" "$BOOK_ENV_HOME_FILE"
  printf '],"hint":"run: bash scripts/book_import.sh --init"}\n'
}

book_load_config() {
  book_resolve_all

  if [ "$VAULT_DIR_SOURCE" = "built-in default" ]; then
    return 1
  fi

  if [ ! -d "$VAULT_DIR" ]; then
    printf '{"ok":false,"error":"vault_dir_not_found","path":"%s","hint":"check VAULT_DIR with --config-info"}\n' \
      "$VAULT_DIR" >&2
    return 2
  fi

  mkdir -p "$BOOK_STATE_DIR" 2>/dev/null
  return 0
}

# Keys are emitted by book_resolve_all in this order; the renderers below read
# the records positionally rather than looking up variables by name.
book_config_info() {
  local fmt="${1:-text}" rec_key rec_val rec_src rc json_sep="" search_sep="" mark sp

  book_load_config
  rc=$?
  if [ $rc -ne 0 ]; then
    [ "$rc" -eq 1 ] && [ "$fmt" = "--json" ] && book_config_not_found_json
    return $rc
  fi

  if [ "$fmt" = "--json" ]; then
    printf '{"ok":true,"settings":{'
    while IFS=$'\t' read -r rec_key rec_val rec_src; do
      [ -n "$rec_key" ] || continue
      printf '%s"%s":{"value":"%s","source":"%s"}' "$json_sep" "$rec_key" "$rec_val" "$rec_src"
      json_sep=","
    done <<EOF
$BOOK_RESOLVED_RECORDS
EOF
    printf '},"searched":['
    while IFS= read -r sp; do
      printf '%s%s' "$search_sep" "$(book_searched_json "$sp")"
      search_sep=","
    done <<EOF
process.env
$BOOK_ENV_PROJECT_FILE
$BOOK_ENV_HOME_FILE
EOF
    printf ']}\n'
    return 0
  fi

  echo "book-enquire-reader — resolved config"
  echo ""
  while IFS=$'\t' read -r rec_key rec_val rec_src; do
    [ -n "$rec_key" ] || continue
    printf '  %-20s %s\n' "$rec_key" "${rec_val:-(empty)}"
  done <<EOF
$BOOK_RESOLVED_RECORDS
EOF
  echo ""
  echo "Sources (highest priority first):"
  while IFS=$'\t' read -r rec_key rec_val rec_src; do
    [ -n "$rec_key" ] || continue
    printf '  %-20s %s\n' "$rec_key" "$rec_src"
  done <<EOF
$BOOK_RESOLVED_RECORDS
EOF
  echo ""
  echo "Search path:"
  while IFS= read -r sp; do
    if [ "$sp" = "process.env" ]; then
      mark="checked"
    elif [ -f "$sp" ]; then
      mark="(found)"
    else
      mark="(absent)"
    fi
    printf '  [%s] %s\n' "$mark" "$sp"
  done <<EOF
process.env
$BOOK_ENV_PROJECT_FILE
$BOOK_ENV_HOME_FILE
EOF
  return 0
}

book_searched_json() {
  local sp="$1"
  if [ "$sp" = "process.env" ]; then
    printf '{"path":"%s","source":"env","status":"present"}' "$sp"
  elif [ -f "$sp" ]; then
    printf '{"path":"%s","source":"file","status":"found"}' "$sp"
  else
    printf '{"path":"%s","source":"file","status":"absent"}' "$sp"
  fi
}

# Normalizes a boolean-ish config value. Anything unrecognised is an error at
# the call site rather than a silent default, because "OCR on" and "OCR off"
# produce very different bills.
book_is_true() {
  case "$1" in
    true|TRUE|True|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}