#!/bin/bash
# book_import.sh — ingest a book into the vault and hand back its retrieval scope.
#
# Human, once:
#   bash scripts/book_import.sh --init
#
# Agent / daily use:
#   bash scripts/book_import.sh --book ~/Books/some.pdf --category psychology
#
# Config resolution — highest priority first:
#   1. process environment            VAULT_DIR=/x bash book_import.sh
#   2. <cwd>/.mario-skills/.env       project-level, shared by all mario skills
#   3. ~/.mario-skills/.env          user-level, shared by all mario skills
#   4. built-in defaults
#
# The receipt's `search_folder` is the whole point of this script: pass it as the
# `folder` argument on every obsidian_search / obsidian_hyde_search call so
# retrieval never returns the digests this skill writes back into the vault.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=book_env.sh
. "$SCRIPT_DIR/book_env.sh"

EXTRACT_PY="$SCRIPT_DIR/book_extract.py"
MANIFEST_FILE=""
BACKUP_ROOT=""

BOOK_PATH=""
BOOK_SLUG=""
BOOK_CATEGORY="uncategorized"
FORCE="false"
DRY_RUN="false"
REINDEX="false"
CONFIG_FMT=""
INIT_REQUESTED="false"
INIT_TARGET="user"
DETECT_REQUESTED="false"

SUPPORTED_EXT="pdf|epub|mobi|txt|text|md"

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

json_escape() {
  # Minimal JSON string escaping. Book slugs and paths can contain quotes and
  # backslashes on Windows-origin vaults.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

err_json() {
  printf '{"ok":false,"error":"%s"' "$1"
  shift
  while [ $# -gt 0 ]; do
    printf ',%s' "$1"
    shift
  done
  printf '}\n'
}

print_help() {
  cat <<'EOF'
book_import.sh — ingest a book into an Obsidian vault for enquire-mcp retrieval

Usage:
  bash scripts/book_import.sh --book <path> [options]

Options:
  --book <path>       Source book: PDF, EPUB, TXT, Markdown, MOBI, HTML
  --slug <name>       Folder name for the book. Default: sanitized filename
  --category <name>   Category folder under BOOKS_SUBDIR. Default: uncategorized
  --force             Re-import even when the content hash is unchanged
  --reindex           Run `enquire-mcp build-embeddings` afterwards (full vault, slow)
  --dry-run           Print what would happen, change nothing on disk

Setup (human only — never from an LLM call):
  --init              First-run wizard, writes ~/.mario-skills/.env
  --init --project    Write <cwd>/.mario-skills/.env instead
  --init --dry-run    Preview the wizard, write nothing
  --detect            List Obsidian vaults found on this machine, write nothing

Inspection:
  --config-info       Print every resolved value, its source layer, and the
                      full search path. Add --json for machine-readable output.

Exit codes:
  0  imported, skipped (unchanged), or --dry-run completed
  1  config not found / vault missing / bad arguments
  2  book path missing, unreadable, or unsupported format
  3  extraction produced no text (scanned or encrypted file)
EOF
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Content hash, used for incremental detection. Falls back to md5 where
# sha256 tooling is unavailable; either is sufficient for change detection.
hash_file() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    md5 -q "$f" 2>/dev/null || md5sum "$f" | awk '{print $1}'
  fi
}

slugify() {
  # Lowercase, non-alphanumerics to single hyphens, no leading/trailing hyphen.
  # ASCII-only on purpose: CJK filenames slugify to nothing useful, so callers
  # should pass --slug explicitly for those.
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-80
}

detect_obsidian_vaults() {
  local json
  for json in \
    "$HOME/Library/Application Support/obsidian/obsidian.json" \
    "$HOME/.config/obsidian/obsidian.json" \
    "${APPDATA:-}/obsidian/obsidian.json"; do
    [ -f "$json" ] || continue
    grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$json" \
      | sed -E 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
    return 0
  done
  return 1
}

cmd_detect() {
  local json="" j tmp count=0 p
  for j in \
    "$HOME/Library/Application Support/obsidian/obsidian.json" \
    "$HOME/.config/obsidian/obsidian.json" \
    "${APPDATA:-}/obsidian/obsidian.json"; do
    [ -f "$j" ] && { json="$j"; break; }
  done

  if [ -z "$json" ]; then
    echo "No Obsidian config found in any of these locations:"
    echo "  macOS:   ~/Library/Application Support/obsidian/obsidian.json"
    echo "  Linux:   ~/.config/obsidian/obsidian.json"
    echo "  Windows: %APPDATA%\\obsidian\\obsidian.json"
    echo ""
    echo "If Obsidian is installed but vaults are not listed, open Obsidian and"
    echo "add the vault once, then re-run --detect. You can also pass a path"
    echo "directly: VAULT_DIR=/path/to/vault bash scripts/book_import.sh --config-info"
    return 0
  fi

  echo "Obsidian vaults found in $json:"
  echo ""
  tmp="$(mktemp -t book-detect-XXXXXX)"
  detect_obsidian_vaults > "$tmp" 2>/dev/null || true
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    count=$((count + 1))
    if [ -d "$p" ]; then
      printf '  [%d] %s\n' "$count" "$p"
    else
      printf '  [%d] %s  (missing on disk)\n' "$count" "$p"
    fi
  done < "$tmp"
  rm -f "$tmp"
  echo ""
  echo "Total: $count vault(s). Offered as defaults by --init."
}

# --------------------------------------------------------------------------
# --init wizard (human only)
# --------------------------------------------------------------------------

ask() {
  # ask VAR "prompt" "default"
  # Prefers /dev/tty so a piped stdin cannot silently answer the wizard. The
  # probe matters: /dev/tty is readable-but-unusable in cron and some CI
  # sandboxes, where `-r` lies and `read` fails with "Device not configured".
  local __var="$1" __prompt="$2" __default="$3" __reply=""
  printf '%s [%s] ' "$__prompt" "$__default" >&2
  if { : </dev/tty; } 2>/dev/null; then
    IFS= read -r __reply </dev/tty || __reply=""
  else
    IFS= read -r __reply || __reply=""
  fi
  [ -z "$__reply" ] && __reply="$__default"
  printf -v "$__var" '%s' "$__reply"
}

cmd_init() {
  local target_file home_or_project detected default_vault tmp detected_n
  local w_vault w_books w_source w_notes w_hyde w_graph w_ocr w_chunks w_bin w_state
  local merged existing new_content action

  if [ "$INIT_TARGET" = "project" ]; then
    target_file="$BOOK_ENV_PROJECT_FILE"
  else
    target_file="$BOOK_ENV_HOME_FILE"
  fi

  # Pre-fill from what is currently resolved, so a re-run shows the live config
  # rather than the built-in defaults.
  book_resolve_all
  w_vault="$VAULT_DIR"
  w_books="$BOOKS_SUBDIR"
  w_source="$BOOK_SOURCE_SUBDIR"
  w_notes="$BOOK_NOTES_SUBDIR"
  w_hyde="$BOOK_HYDE"
  w_graph="$BOOK_GRAPH"
  w_ocr="$BOOK_OCR"
  w_chunks="$BOOK_MAX_CHUNKS"
  w_bin="$BOOK_ENQUIRE_BIN"
  w_state="$BOOK_STATE_DIR"

  detected=""
  tmp="$(mktemp -t book-init-XXXXXX)"
  detect_obsidian_vaults > "$tmp" 2>/dev/null || true
  detected_n="$(grep -c . "$tmp" 2>/dev/null || echo 0)"
  if [ "$detected_n" = "1" ]; then
    detected="$(grep . "$tmp" | head -1)"
    default_vault="$detected"
    detected="  (detected from Obsidian config)"
  elif [ "$detected_n" -gt 1 ] 2>/dev/null; then
    default_vault="$BOOK_DEFAULT_VAULT_DIR"
    detected=""
    echo "Multiple vaults detected — enter the number or paste a path:" >&2
    n=0
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      n=$((n + 1))
      printf '  [%d] %s\n' "$n" "$p" >&2
    done < "$tmp"
  else
    default_vault="$BOOK_DEFAULT_VAULT_DIR"
    detected=""
  fi
  rm -f "$tmp"

  [ -z "$detected" ] && default_vault="${VAULT_DIR:-$BOOK_DEFAULT_VAULT_DIR}"

  echo "" >&2
  echo "book-enquire-reader setup — writing to $target_file" >&2
  echo "" >&2

  ask w_vault      "Vault root"                "$default_vault"
  ask w_books      "Books folder"              "$w_books"
  ask w_source     "Retrieval folder name"     "$w_source"
  ask w_notes      "Notes folder name"         "$w_notes"
  ask w_hyde       "HyDE retrieval (true/false)" "$w_hyde"
  ask w_graph      "GraphRAG communities (true/false)" "$w_graph"
  ask w_ocr        "OCR for scanned PDFs (true/false)" "$w_ocr"
  ask w_chunks     "Max chunks per query"      "$w_chunks"
  ask w_bin        "enquire-mcp executable"    "$w_bin"
  ask w_state      "State dir (hashes/backups)" "$w_state"

  case "$w_vault" in "~") w_vault="$HOME" ;; "~/"*) w_vault="$HOME/${w_vault#\~/}" ;; esac

  if [ "$DRY_RUN" = "true" ]; then
    echo "" >&2
    echo "Would merge into $target_file:" >&2
    printf 'VAULT_DIR=%s\nBOOKS_SUBDIR=%s\nBOOK_SOURCE_SUBDIR=%s\nBOOK_NOTES_SUBDIR=%s\n' \
      "$w_vault" "$w_books" "$w_source" "$w_notes" >&2
    printf 'BOOK_HYDE=%s\nBOOK_GRAPH=%s\nBOOK_OCR=%s\nBOOK_MAX_CHUNKS=%s\n' \
      "$w_hyde" "$w_graph" "$w_ocr" "$w_chunks" >&2
    printf 'BOOK_ENQUIRE_BIN=%s\nBOOK_STATE_DIR=%s\n' "$w_bin" "$w_state" >&2
    echo "" >&2
    echo "Nothing was changed." >&2
    return 0
  fi

  mkdir -p "$(dirname "$target_file")"
  [ -f "$target_file" ] && cp -p "$target_file" "$target_file.bak.$(date +%Y%m%d%H%M%S)"

  # Merged write: strip this skill's own keys, then append a fresh block.
  # Every other key in the file — sibling skills, user comments — survives.
  merged="$(mktemp -t book-merge-XXXXXX)"
  if [ -f "$target_file" ]; then
    grep -vE '^(export[[:space:]]+)?(VAULT_DIR|BOOKS_SUBDIR|BOOK_SOURCE_SUBDIR|BOOK_NOTES_SUBDIR|BOOK_HYDE|BOOK_GRAPH|BOOK_OCR|BOOK_MAX_CHUNKS|BOOK_ENQUIRE_BIN|BOOK_STATE_DIR)=' \
      "$target_file" > "$merged"
  else
    printf '# mario-skills shared environment\n# Read by every skill. Never commit.\n\n' > "$merged"
  fi

  {
    printf '\n# --- book-enquire-reader --------------------------------------------\n'
    printf 'VAULT_DIR=%s\n' "$w_vault"
    printf 'BOOKS_SUBDIR=%s\n' "$w_books"
    printf 'BOOK_SOURCE_SUBDIR=%s\n' "$w_source"
    printf 'BOOK_NOTES_SUBDIR=%s\n' "$w_notes"
    printf 'BOOK_HYDE=%s\n' "$w_hyde"
    printf 'BOOK_GRAPH=%s\n' "$w_graph"
    printf 'BOOK_OCR=%s\n' "$w_ocr"
    printf 'BOOK_MAX_CHUNKS=%s\n' "$w_chunks"
    printf 'BOOK_ENQUIRE_BIN=%s\n' "$w_bin"
    printf 'BOOK_STATE_DIR=%s\n' "$w_state"
  } >> "$merged"

  if mv "$merged" "$target_file"; then
    chmod 600 "$target_file" 2>/dev/null
    # v0.5+: ensure the configured books root exists so a fresh --init does
    # not leave a dangling BOOKS_SUBDIR. mkdir -p is idempotent; --dry-run
    # branches earlier and never reaches here.
    mkdir -p "$w_vault/$w_books" 2>/dev/null
    action="config_written"
  else
    rm -f "$merged"
    action="config_write_failed"
  fi

  printf '{"ok":%s,"action":"%s","path":"%s","keys":["VAULT_DIR","BOOKS_SUBDIR","BOOK_SOURCE_SUBDIR","BOOK_NOTES_SUBDIR","BOOK_HYDE","BOOK_GRAPH","BOOK_OCR","BOOK_MAX_CHUNKS","BOOK_ENQUIRE_BIN","BOOK_STATE_DIR"],"note":"merged in place; keys you did not answer were kept, and a .bak.<timestamp> copy of the previous file sits alongside"}\n' \
    "$([ "$action" = "config_written" ] && echo true || echo false)" \
    "$action" "$target_file"
}

# --------------------------------------------------------------------------
# Manifest (incremental import detection)
# --------------------------------------------------------------------------

manifest_get() {
  # slug<TAB>hash<TAB>category<TAB>date<TAB>source_name
  [ -f "$MANIFEST_FILE" ] || return 1
  awk -F'\t' -v s="$1" '$1 == s { print $2; found=1 } END { exit !found }' "$MANIFEST_FILE"
}

manifest_set() {
  # Rewrite the row for SLUG, preserving every other book's row.
  local tmp
  tmp="$(mktemp -t book-manifest-XXXXXX)"
  if [ -f "$MANIFEST_FILE" ]; then
    awk -F'\t' -v s="$1" '$1 != s' "$MANIFEST_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$tmp"
  mv "$tmp" "$MANIFEST_FILE"
}

manifest_remove() {
  local tmp
  [ -f "$MANIFEST_FILE" ] || return 0
  tmp="$(mktemp -t book-manifest-XXXXXX)"
  awk -F'\t' -v s="$1" '$1 != s' "$MANIFEST_FILE" > "$tmp"
  mv "$tmp" "$MANIFEST_FILE"
}

# --------------------------------------------------------------------------
# Import
# --------------------------------------------------------------------------

do_import() {
  local abs_book ext base_slug target_dir source_dir book_folder search_folder
  local content_hash prev_hash stamp backup_dir rel_source is_extract=0
  local extracted_md="" nrc

  [ -n "$BOOK_PATH" ] || {
    err_json "book_required" '"hint":"pass --book <path>"'
    return 1
  }
  abs_book="$(cd "$(dirname "$BOOK_PATH")" 2>/dev/null && pwd)/$(basename "$BOOK_PATH")"
  [ -f "$abs_book" ] || {
    err_json "book_not_found" "\"path\":\"$(json_escape "$abs_book")\""
    return 2
  }
  [ -r "$abs_book" ] || {
    err_json "book_unreadable" "\"path\":\"$(json_escape "$abs_book")\""
    return 2
  }

  # Scope check (v0.5+): source file must live under <VAULT_DIR>/<BOOKS_SUBDIR>.
  # Phase 0 normally copies the file into scope before calling. This is
  # defense-in-depth: a direct `book_import.sh --book /tmp/foo.pdf` invocation
  # gets refused with scope_error rather than silently importing into the wrong
  # place. case-glob prefix match — no realpath, no macOS bash 3.2 gotchas.
  BOOK_RAW_DIR_ABS="$VAULT_DIR/$BOOKS_SUBDIR"
  case "$abs_book" in
    "$BOOK_RAW_DIR_ABS"/*) ;;  # in scope, continue
    *)
      err_json "scope_error" \
        "\"file\":\"$(json_escape "$abs_book")\"" \
        "\"scope\":\"$(json_escape "$BOOK_RAW_DIR_ABS")\"" \
        '"hint":"this skill only processes files under <VAULT_DIR>/<BOOKS_SUBDIR>. Move the file there, or use Phase 0 to copy it into scope."'
      return 2
      ;;
  esac

  ext="$(printf '%s' "${abs_book##*.}" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$ext" | grep -qE "^($SUPPORTED_EXT)$" || {
    err_json "unsupported_format" \
      "\"ext\":\"$(json_escape "$ext")\"" \
      '"supported":"pdf, epub, mobi, txt, text, md"' \
      '"hint":"this skill only processes these 6 formats. Other formats (html/azw3/markdown) belong to other skills."'
    return 2
  }

  # Base name without extension, used as the slug seed.
  base_slug="$(basename "$abs_book")"
  base_slug="${base_slug%.*}"
  if [ -n "$BOOK_SLUG" ]; then
    base_slug="$BOOK_SLUG"
  else
    base_slug="$(slugify "$base_slug")"
    if [ -z "$base_slug" ]; then
      err_json "slug_undetermined" \
        "\"book\":\"$(json_escape "$(basename "$abs_book")")\"" \
        '"hint":"non-ASCII filename — pass --slug <name> explicitly"'
      return 2
    fi
  fi

  book_folder="$BOOKS_SUBDIR/$BOOK_CATEGORY/$base_slug"
  target_dir="$VAULT_DIR/$book_folder"
  source_dir="$target_dir/$BOOK_SOURCE_SUBDIR"
  search_folder="$book_folder/$BOOK_SOURCE_SUBDIR"

  content_hash="$(hash_file "$abs_book")"
  prev_hash="$(manifest_get "$base_slug" || true)"

  # --dry-run reports the plan even for an unchanged book. "skip_unchanged" is
  # the truthful answer for a real run, but answering it to a preview tells the
  # caller nothing about what would have happened.
  if [ "$DRY_RUN" != "true" ] && [ "$FORCE" != "true" ] && [ -n "$prev_hash" ] \
     && [ "$prev_hash" = "$content_hash" ] && [ -d "$source_dir" ]; then
    printf '{"ok":true,"action":"skip_unchanged","slug":"%s","hash":"%s","book_folder":"%s","search_folder":"%s"}\n' \
      "$(json_escape "$base_slug")" "$content_hash" \
      "$(json_escape "$book_folder")" "$(json_escape "$search_folder")"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    local would="import"
    if [ -n "$prev_hash" ] && [ "$prev_hash" = "$content_hash" ]; then
      would="skip (content unchanged; pass --force to re-import anyway)"
    fi
    case "$ext" in
      pdf|md|markdown) rel_source="$BOOK_SOURCE_SUBDIR/$(basename "$abs_book")" ;;
      *) rel_source="$BOOK_SOURCE_SUBDIR/$base_slug.md" ;;
    esac
    printf '{"ok":true,"action":"dry_run","slug":"%s","book_folder":"%s","search_folder":"%s","would_write":"%s","would":"%s","previous_hash":"%s","new_hash":"%s","would_backup":%s}\n' \
      "$(json_escape "$base_slug")" "$(json_escape "$book_folder")" \
      "$(json_escape "$search_folder")" "$(json_escape "$rel_source")" \
      "$(json_escape "$would")" "${prev_hash:-none}" "$content_hash" \
      "$([ -d "$target_dir" ] && echo true || echo false)"
    return 0
  fi

  # Back up before mutating a user directory.
  if [ -d "$target_dir" ] && [ -n "$(ls -A "$target_dir" 2>/dev/null)" ]; then
    stamp="$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BACKUP_ROOT"
    backup_dir="$BACKUP_ROOT/$base_slug-$stamp"
    if cp -R "$target_dir" "$backup_dir" 2>/dev/null; then
      :
    else
      err_json "backup_failed" "\"target\":\"$(json_escape "$target_dir")\"" \
        '"hint":"nothing was modified"'
      return 1
    fi
  else
    backup_dir=""
  fi

  mkdir -p "$source_dir" || {
    err_json "mkdir_failed" "\"path\":\"$(json_escape "$source_dir")\""
    return 1
  }

  case "$ext" in
    pdf|md|markdown)
      rel_source="$BOOK_SOURCE_SUBDIR/$(basename "$abs_book")"
      if ! cp -f "$abs_book" "$target_dir/$rel_source"; then
        err_json "copy_failed" "\"source\":\"$(json_escape "$abs_book")\"" \
          "\"destination\":\"$(json_escape "$target_dir/$rel_source")\""
        return 1
      fi
      ;;
    *)
      is_extract=1
      rel_source="$BOOK_SOURCE_SUBDIR/$base_slug.md"
      # Keep the original beside the extraction for provenance. enquire ignores
      # formats it cannot parse, so it never enters the retrieval pool.
      cp -f "$abs_book" "$source_dir/original.$ext" 2>/dev/null
      extracted_md="$target_dir/$rel_source"
      # The extractor prints its own receipt; send it to stderr so stdout
      # carries exactly one JSON object — this script's receipt.
      python3 "$EXTRACT_PY" "$abs_book" -o "$extracted_md" --title "$base_slug" >&2
      nrc=$?
      if [ $nrc -ne 0 ]; then
        err_json "extract_failed" "\"book\":\"$(json_escape "$abs_book")\"" \
          "\"exit\":$nrc" \
          '"hint":"scanned PDFs need BOOK_OCR=true plus `enquire-mcp install-ocr-lang <code>`; MOBI needs calibre (brew install calibre)"'
        return 3
      fi
      ;;
  esac

  manifest_set "$base_slug" "$content_hash" "$BOOK_CATEGORY" \
    "$(date +%Y-%m-%d)" "$(basename "$abs_book")"

  local reindexed="skipped"
  if [ "$REINDEX" = "true" ]; then
    if command -v "$BOOK_ENQUIRE_BIN" >/dev/null 2>&1; then
      if "$BOOK_ENQUIRE_BIN" build-embeddings --vault "$VAULT_DIR" >/dev/null 2>&1; then
        reindexed="ok"
      else
        reindexed="failed"
      fi
    else
      reindexed="enquire_not_found"
    fi
  fi

  local action="imported"
  [ "$is_extract" = "1" ] && action="imported_extracted"

  printf '{"ok":true,"action":"%s","slug":"%s","hash":"%s","book_folder":"%s","search_folder":"%s","source":"%s","backup":"%s","reindex":"%s"}\n' \
    "$action" \
    "$(json_escape "$base_slug")" \
    "$content_hash" \
    "$(json_escape "$book_folder")" \
    "$(json_escape "$search_folder")" \
    "$(json_escape "$rel_source")" \
    "$(json_escape "${backup_dir:-none}")" \
    "$reindexed"
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --book)     BOOK_PATH="${2:-}"; shift 2 ;;
    --book=*)   BOOK_PATH="${1#--book=}"; shift ;;
    --slug)     BOOK_SLUG="${2:-}"; shift 2 ;;
    --slug=*)   BOOK_SLUG="${1#--slug=}"; shift ;;
    --category) BOOK_CATEGORY="${2:-}"; shift 2 ;;
    --category=*) BOOK_CATEGORY="${1#--category=}"; shift ;;
    --force)    FORCE="true"; shift ;;
    --dry-run)  DRY_RUN="true"; shift ;;
    --reindex)  REINDEX="true"; shift ;;
    --init)     INIT_REQUESTED="true"; shift ;;
    --detect)   DETECT_REQUESTED="true"; shift ;;
    --project)  INIT_TARGET="project"; shift ;;
    --config-info)
      CONFIG_FMT="text"; shift
      [ "${1:-}" = "--json" ] && { CONFIG_FMT="json"; shift; }
      ;;
    --config-info=*)
      CONFIG_FMT="${1#--config-info=}"; shift ;;
    --json)     CONFIG_FMT="json"; shift ;;
    --help|-h)  print_help; exit 0 ;;
    --version|-V) echo "book_import.sh — part of book-enquire-reader"; exit 0 ;;
    *)
      printf '❌ Unknown argument: %s\nRun with --help for usage.\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ "$INIT_REQUESTED" = "true" ]; then
  cmd_init
  exit $?
fi

if [ "$DETECT_REQUESTED" = "true" ]; then
  cmd_detect
  exit 0
fi

if [ -n "$CONFIG_FMT" ]; then
  book_config_info "$([ "$CONFIG_FMT" = "json" ] && echo --json || echo text)"
  exit $?
fi

book_load_config
rc=$?
if [ $rc -eq 1 ]; then
  book_config_not_found_json
  echo "" >&2
  echo "VAULT_DIR was not found in any layer. Run --init once, or set:" >&2
  echo "  VAULT_DIR=/path/to/vault bash scripts/book_import.sh --book ..." >&2
  exit 1
elif [ $rc -ne 0 ]; then
  exit 1
fi

MANIFEST_FILE="$BOOK_STATE_DIR/manifest.tsv"
BACKUP_ROOT="$BOOK_STATE_DIR/backups"

do_import
exit $?