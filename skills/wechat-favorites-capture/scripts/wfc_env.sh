#!/bin/bash
# wfc_env.sh — shared .env resolution for wechat-favorites-capture.
#
# Sourced, never executed. Provides:
#   env_get KEY FILE      read one KEY=VALUE from a dotenv file
#   wfc_load_config      walk the priority chain, assign the resolved values
#   wfc_config_info      print resolved values plus the layer that supplied each
#
# `.mario-skills/.env` is the only config file, marketplace-wide. Sibling skills
# read the same file, so a key is written once and every skill sees it. Keys this
# skill does not recognize are ignored — that is what lets one file serve every
# skill.
#
# Resolution order, highest priority first:
#   1. process environment          VAULT_DIR=/x bash wfc_capture.sh all
#   2. <cwd>/.mario-skills/.env     project-level
#   3. ~/.mario-skills/.env        user-level
#   4. built-in defaults
#
# Values are PARSED, never `source`d. A .env may contain `$(...)` or `;`;
# sourcing it would hand arbitrary code execution to a credentials file.

# Overridable so tests and unusual layouts can relocate the two files.
WFC_ENV_HOME_FILE="${MARIO_SKILLS_ENV:-$HOME/.mario-skills/.env}"
WFC_ENV_PROJECT_FILE="${MARIO_SKILLS_PROJECT_ENV:-$PWD/.mario-skills/.env}"

# The save location. The user's brief was "default to /raw", so the default
# path inside the vault is `raw/` and the dataset lives in a named subfolder of
# it. Both are relative to VAULT_DIR and may be absolute.
WFC_DEFAULT_VAULT_DIR="$HOME/Documents/Obsidian"
WFC_DEFAULT_OUT_SUBDIR="raw"
WFC_DEFAULT_SET_SUBDIR="WeChat-Favorites"

# Capture scope. T1 = AI-era (2024+); T2 = pre-2024 material the personal
# audience still cares about; T3 = legacy technical detail; all = no filter.
WFC_DEFAULT_TIER="T1"
WFC_DEFAULT_LIMIT="0"      # 0 = no cap
WFC_DEFAULT_CHUNK="6"      # articles per browser session
WFC_DEFAULT_DELAY="20"     # seconds between articles
WFC_DEFAULT_TAG="wechat-favorites"
WFC_DEFAULT_SESSION="wxscrape"
WFC_DEFAULT_STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/wechat-favorites-capture"
WFC_DEFAULT_DB=""          # empty = auto-detect the WeChat favorite.db
WFC_DEFAULT_VIZ_SKILL=""   # empty = auto-detect
WFC_DEFAULT_SCRAPER_SKILL=""
WFC_DEFAULT_OPENCLI="opencli"

# Snapshot the inherited process environment before anything reassigns these
# names. resolve_setting reads the snapshot, never the live variable — otherwise
# a second call would mistake the first call's result for process.env.
#
# The `-` default is a marker, not a plain empty string: `VAR=` in the
# environment means "explicitly empty" and must override a non-empty built-in
# default, while an absent VAR means "not set". Plain `${VAR-}` cannot tell
# those two apart.
WFC_UNSET="__MARIO_SKILLS_UNSET__"
WFC_SNAP_VAULT_DIR="${VAULT_DIR-$WFC_UNSET}"
WFC_SNAP_OUT_SUBDIR="${WX_FAV_OUT_SUBDIR-$WFC_UNSET}"
WFC_SNAP_SET_SUBDIR="${WX_FAV_SET_SUBDIR-$WFC_UNSET}"
WFC_SNAP_TIER="${WX_FAV_TIER-$WFC_UNSET}"
WFC_SNAP_LIMIT="${WX_FAV_LIMIT-$WFC_UNSET}"
WFC_SNAP_CHUNK="${WX_FAV_CHUNK-$WFC_UNSET}"
WFC_SNAP_DELAY="${WX_FAV_DELAY-$WFC_UNSET}"
WFC_SNAP_TAG="${WX_FAV_TAG-$WFC_UNSET}"
WFC_SNAP_SESSION="${WX_FAV_SESSION-$WFC_UNSET}"
WFC_SNAP_STATE_DIR="${WX_FAV_STATE_DIR-$WFC_UNSET}"
WFC_SNAP_DB="${WX_FAV_DB-$WFC_UNSET}"
WFC_SNAP_VIZ_SKILL="${WX_FAV_VIZ_SKILL-$WFC_UNSET}"
WFC_SNAP_SCRAPER_SKILL="${WX_FAV_SCRAPER_SKILL-$WFC_UNSET}"
WFC_SNAP_OPENCLI="${OPENCLI_BIN-$WFC_UNSET}"

# Prints KEY's value from a dotenv file; last definition wins. Returns 1 when
# the key is absent, so callers can chain layers with `elif val=$(...)`.
env_get() {
  # Returns 0 when the key is PRESENT — even when its value is empty. A key
  # whose value is legitimately empty (`WX_FAV_SET_SUBDIR=` means "store the
  # dataset directly in the save root") must not be confused with a key that
  # was never written.
  local want="$1" file="$2" line key val found="" hit=0
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

    if [ "$key" = "$want" ]; then
      found="$val"
      hit=1
    fi
  done < "$file"

  [ "$hit" = "1" ] || return 1
  printf '%s' "$found"
}

# Walks the priority chain for KEY and records which layer answered.
#
# Records go into WFC_RESOLVED_RECORDS rather than RESOLVED_<KEY> /
# SOURCE_<KEY> variables: reading those back would require indirect expansion,
# and dynamic variable lookup is exactly what this skill is better off without.
wfc_resolve_setting() {
  local key="$1" current="$2" default="$3"
  local val="" src=""

  if [ "$current" != "$WFC_UNSET" ]; then
    val="$current"
    src="process.env"
  elif val="$(env_get "$key" "$WFC_ENV_PROJECT_FILE")"; then
    src="<cwd>/.mario-skills/.env"
  elif val="$(env_get "$key" "$WFC_ENV_HOME_FILE")"; then
    src="~/.mario-skills/.env"
  else
    val="$default"
    src="built-in default"
  fi

  # CURRENT is the process.env snapshot passed in by the caller, never a
  # variable written here — reading one back would make the second call treat
  # its result as process.env.
  WFC_RESOLVED_RECORDS="${WFC_RESOLVED_RECORDS}${key}"$'\x1f'"${val}"$'\x1f'"${src}"$'\n'
}

# Expands a leading ~ so paths can be written that way in the .env.
wfc_expand_tilde() {
  local v="$1"
  case "$v" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${v#\~/}" ;;
    *) printf '%s' "$v" ;;
  esac
}

# Resolves every key this skill owns, per key independently: setting only
# VAULT_DIR must not reset the other twelve to defaults.
#
# Records are emitted in this order, and the --config-info renderers read them
# positionally:
#   VAULT_DIR WX_FAV_OUT_SUBDIR WX_FAV_SET_SUBDIR WX_FAV_TIER WX_FAV_LIMIT
#   WX_FAV_CHUNK WX_FAV_DELAY WX_FAV_TAG WX_FAV_SESSION WX_FAV_STATE_DIR
#   WX_FAV_DB
#   WX_FAV_VIZ_SKILL WX_FAV_SCRAPER_SKILL OPENCLI_BIN
wfc_resolve_all() {
  WFC_RESOLVED_RECORDS=""

  wfc_resolve_setting VAULT_DIR           "$WFC_SNAP_VAULT_DIR"      "$WFC_DEFAULT_VAULT_DIR"
  wfc_resolve_setting WX_FAV_OUT_SUBDIR   "$WFC_SNAP_OUT_SUBDIR"    "$WFC_DEFAULT_OUT_SUBDIR"
  wfc_resolve_setting WX_FAV_SET_SUBDIR   "$WFC_SNAP_SET_SUBDIR"    "$WFC_DEFAULT_SET_SUBDIR"
  wfc_resolve_setting WX_FAV_TIER         "$WFC_SNAP_TIER"          "$WFC_DEFAULT_TIER"
  wfc_resolve_setting WX_FAV_LIMIT        "$WFC_SNAP_LIMIT"         "$WFC_DEFAULT_LIMIT"
  wfc_resolve_setting WX_FAV_CHUNK        "$WFC_SNAP_CHUNK"         "$WFC_DEFAULT_CHUNK"
  wfc_resolve_setting WX_FAV_DELAY        "$WFC_SNAP_DELAY"         "$WFC_DEFAULT_DELAY"
  wfc_resolve_setting WX_FAV_TAG          "$WFC_SNAP_TAG"           "$WFC_DEFAULT_TAG"
  wfc_resolve_setting WX_FAV_SESSION      "$WFC_SNAP_SESSION"       "$WFC_DEFAULT_SESSION"
  wfc_resolve_setting WX_FAV_STATE_DIR    "$WFC_SNAP_STATE_DIR"     "$WFC_DEFAULT_STATE_DIR"
  wfc_resolve_setting WX_FAV_DB           "$WFC_SNAP_DB"            "$WFC_DEFAULT_DB"
  wfc_resolve_setting WX_FAV_VIZ_SKILL    "$WFC_SNAP_VIZ_SKILL"     "$WFC_DEFAULT_VIZ_SKILL"
  wfc_resolve_setting WX_FAV_SCRAPER_SKILL "$WFC_SNAP_SCRAPER_SKILL" "$WFC_DEFAULT_SCRAPER_SKILL"
  wfc_resolve_setting OPENCLI_BIN         "$WFC_SNAP_OPENCLI"       "$WFC_DEFAULT_OPENCLI"

  # Second pass: pull the resolved values back out by position to assign the
  # plain variables the rest of the scripts read. Only the path keys get ~ expansion.
  local rec
  while IFS=$'\x1f' read -r rec_key rec rec_src; do
    case "$rec_key" in
      VAULT_DIR)           VAULT_DIR="$(wfc_expand_tilde "$rec")"; VAULT_DIR_SOURCE="$rec_src" ;;
      WX_FAV_OUT_SUBDIR)   WX_FAV_OUT_SUBDIR="$rec" ;;
      WX_FAV_SET_SUBDIR)   WX_FAV_SET_SUBDIR="$rec" ;;
      WX_FAV_TIER)         WX_FAV_TIER="$rec" ;;
      WX_FAV_LIMIT)        WX_FAV_LIMIT="$rec" ;;
      WX_FAV_CHUNK)        WX_FAV_CHUNK="$rec" ;;
      WX_FAV_DELAY)        WX_FAV_DELAY="$rec" ;;
      WX_FAV_TAG)          WX_FAV_TAG="$rec" ;;
      WX_FAV_SESSION)      WX_FAV_SESSION="$rec" ;;
      WX_FAV_STATE_DIR)    WX_FAV_STATE_DIR="$(wfc_expand_tilde "$rec")" ;;
      WX_FAV_DB)           WX_FAV_DB="$(wfc_expand_tilde "$rec")" ;;
      WX_FAV_VIZ_SKILL)    WX_FAV_VIZ_SKILL="$(wfc_expand_tilde "$rec")" ;;
      WX_FAV_SCRAPER_SKILL) WX_FAV_SCRAPER_SKILL="$(wfc_expand_tilde "$rec")" ;;
      OPENCLI_BIN)         OPENCLI_BIN="$rec" ;;
    esac
  done <<EOF
$WFC_RESOLVED_RECORDS
EOF
}

# The JSON error a missing VAULT_DIR produces. It enumerates EVERY location
# searched so the agent can relay `searched` verbatim instead of paraphrasing.
wfc_config_not_found_json() {
  printf '{"ok":false,"error":"config_not_found","searched":['
  printf '"process.env","%s","%s"' "$WFC_ENV_PROJECT_FILE" "$WFC_ENV_HOME_FILE"
  printf '],"hint":"run: bash scripts/wfc_setup.sh --init"}\n'
}

wfc_load_config() {
  wfc_resolve_all

  if [ "$VAULT_DIR_SOURCE" = "built-in default" ]; then
    return 1
  fi

  if [ ! -d "$VAULT_DIR" ]; then
    printf '{"ok":false,"error":"vault_dir_not_found","path":"%s","hint":"check VAULT_DIR with --config-info"}\n' \
      "$VAULT_DIR" >&2
    return 2
  fi

  mkdir -p "$WX_FAV_STATE_DIR" 2>/dev/null
  return 0
}

# The dataset directory: <vault>/<out-subdir>/<set-subdir>. Both parts may be
# absolute, in which case the absolute one wins outright. An empty set-subdir
# means "store directly in the save root" — the user asked for "raw" and got
# exactly raw, without an extra folder in between.
wfc_dataset_dir() {
  local out="$WX_FAV_OUT_SUBDIR" set="$WX_FAV_SET_SUBDIR" root
  case "$out" in
    /*) root="$out" ;;
    *)  root="$VAULT_DIR/$out" ;;
  esac
  case "$set" in
    "")  printf '%s' "$root" ;;
    /*)  printf '%s' "$set" ;;
    *)   printf '%s/%s' "$root" "$set" ;;
  esac
}

# Where the scraped articles land: <dataset>/articles/<category>/
wfc_articles_dir() {
  printf '%s/articles' "$(wfc_dataset_dir)"
}

wfc_is_true() {
  case "$1" in
    true|TRUE|True|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Escapes a value for embedding in a JSON string.
wfc_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\x1f'/\\u001f}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

wfc_searched_json() {
  local sp="$1"
  if [ "$sp" = "process.env" ]; then
    printf '{"path":"%s","source":"env","status":"present"}' "$sp"
  elif [ -f "$sp" ]; then
    printf '{"path":"%s","source":"file","status":"found"}' "$sp"
  else
    printf '{"path":"%s","source":"file","status":"absent"}' "$sp"
  fi
}

# Keys are emitted by wfc_resolve_all in this order; the renderers below read
# the records positionally rather than looking up variables by name.
wfc_config_info() {
  local fmt="${1:-text}" rec_key rec_val rec_src rc json_sep="" search_sep="" mark sp

  wfc_load_config
  rc=$?
  if [ $rc -ne 0 ]; then
    [ "$rc" -eq 1 ] && [ "$fmt" = "--json" ] && wfc_config_not_found_json
    return $rc
  fi

  if [ "$fmt" = "--json" ]; then
    printf '{"ok":true,"settings":{'
    while IFS=$'\x1f' read -r rec_key rec_val rec_src; do
      [ -n "$rec_key" ] || continue
      printf '%s"%s":{"value":"%s","source":"%s"}' "$json_sep" "$rec_key" "$(wfc_json_escape "$rec_val")" "$rec_src"
      json_sep=","
    done <<EOF
$WFC_RESOLVED_RECORDS
EOF
    printf '},"searched":['
    while IFS= read -r sp; do
      printf '%s%s' "$search_sep" "$(wfc_searched_json "$sp")"
      search_sep=","
    done <<EOF
process.env
$WFC_ENV_PROJECT_FILE
$WFC_ENV_HOME_FILE
EOF
    printf ']}\n'
    return 0
  fi

  echo "wechat-favorites-capture — resolved config"
  echo ""
  while IFS=$'\x1f' read -r rec_key rec_val rec_src; do
    [ -n "$rec_key" ] || continue
    printf '  %-24s %s\n' "$rec_key" "${rec_val:-(empty)}"
  done <<EOF
$WFC_RESOLVED_RECORDS
EOF
  echo ""
  echo "Sources (highest priority first):"
  while IFS=$'\x1f' read -r rec_key rec_val rec_src; do
    [ -n "$rec_key" ] || continue
    printf '  %-24s %s\n' "$rec_key" "$rec_src"
  done <<EOF
$WFC_RESOLVED_RECORDS
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
$WFC_ENV_PROJECT_FILE
$WFC_ENV_HOME_FILE
EOF
  echo ""
  echo "Dataset dir: $(wfc_dataset_dir)"
  return 0
}
