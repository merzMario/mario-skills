#!/bin/bash
# book_admin.sh — inspect and maintain books imported by book-enquire-reader.
#
#   bash scripts/book_admin.sh status     # is the retrieval layer actually usable?
#   bash scripts/book_admin.sh list       # what has been imported
#   bash scripts/book_admin.sh verify     # does anything on disk disagree with the manifest
#   bash scripts/book_admin.sh remove <slug> [--delete]
#
# `status` is the one to run first when a search returns nothing. Most "the
# book isn't findable" reports are an index that was never built, not a broken
# import.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=book_env.sh
. "$SCRIPT_DIR/book_env.sh"

CMD="${1:-}"
MANIFEST_FILE=""
DRY_RUN="false"
DELETE_DIR="false"
TARGET_SLUG=""

print_help() {
  cat <<'EOF'
book_admin.sh — inspect and maintain imported books

Usage:
  bash scripts/book_admin.sh status
  bash scripts/book_admin.sh list
  bash scripts/book_admin.sh verify
  bash scripts/book_admin.sh remove <slug> [--delete] [--dry-run]

Commands:
  status        Report whether PDF blending, embeddings, and OCR are available
  list          List every book in the import manifest
  verify        Compare each manifest row against what is actually on disk
  remove <slug> Forget a book. Adds --delete to also delete its vault folder,
                and --dry-run to preview either.

Exit codes:
  0  success (verify reports problems via `ok:false` on stdout)
  1  config missing, bad arguments, or the requested slug is unknown
EOF
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

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

manifest_remove() {
  local tmp
  [ -f "$MANIFEST_FILE" ] || return 0
  tmp="$(mktemp -t book-manifest-XXXXXX)"
  awk -F'\t' -v s="$1" '$1 != s' "$MANIFEST_FILE" > "$tmp"
  mv "$tmp" "$MANIFEST_FILE"
}

print_help_and_exit() { print_help; exit 1; }

# --------------------------------------------------------------------------

cmd_status() {
  local bin embed_db pdfs ocr_packs
  printf 'book-enquire-reader — retrieval status\n\n'

  printf '  %-22s %s\n' "Vault" "$VAULT_DIR"
  printf '  %-22s %s\n' "Books folder" "$BOOKS_SUBDIR"
  printf '  %-22s %s\n' "Books root (abs)" "$VAULT_DIR/$BOOKS_SUBDIR"
  printf '  %-22s %s\n' "Retrieval folder" "$BOOK_SOURCE_SUBDIR"
  printf '  %-22s %s\n' "Notes folder" "$BOOK_NOTES_SUBDIR"
  echo ""

  if command -v "$BOOK_ENQUIRE_BIN" >/dev/null 2>&1; then
    printf '  %-22s %s (%s)\n' "enquire-mcp" "$BOOK_ENQUIRE_BIN" \
      "$("$BOOK_ENQUIRE_BIN" --version 2>/dev/null | head -1)"
  else
    printf '  %-22s %s\n' "enquire-mcp" "NOT FOUND on PATH"
    echo "    install: npm install -g @oomkapwn/enquire-mcp"
  fi

  embed_db="$(find "$VAULT_DIR" -maxdepth 2 -name '.embed.db' 2>/dev/null | head -1)"
  if [ -n "$embed_db" ]; then
    printf '  %-22s %s\n' "Embedding index" "present ($embed_db)"
  else
    printf '  %-22s %s\n' "Embedding index" "absent"
    echo "    without it, obsidian_search falls back to TF-IDF/BM25 only —"
    echo "    run: enquire-mcp setup --vault \"$VAULT_DIR\""
  fi

  # Depth 6 reaches <vault>/<BOOKS>/<category>/<slug>/<SOURCE>/<file>.pdf.
  pdfs="$(find "$VAULT_DIR/$BOOKS_SUBDIR" -maxdepth 6 -iname '*.pdf' 2>/dev/null | wc -l | tr -d ' ')"
  printf '  %-22s %s\n' "PDFs in vault" "$pdfs"
  if [ "$pdfs" -gt 0 ]; then
    echo "    PDF page citations require enquire-mcp to have been started with"
    echo "    --include-pdfs, and obsidian_read_pdf to be available."
  fi

  if book_is_true "$BOOK_OCR"; then
    ocr_packs="configured on"
    echo "    OCR is ON: scanned pages need \`enquire-mcp install-ocr-lang <code>\`"
    echo "    before obsidian_ocr_pdf will work. ~1-2s per page on CPU."
  else
    ocr_packs="off"
  fi
  printf '  %-22s %s\n' "OCR" "$ocr_packs"

  if [ -z "$(ls -A "$BOOK_STATE_DIR/manifest.tsv" 2>/dev/null)" ]; then
    echo ""
    echo "  No books imported yet. Start with:"
    echo "    bash scripts/book_import.sh --book /path/to/book.epub"
  fi
}

cmd_list() {
  if [ ! -f "$MANIFEST_FILE" ] || [ -z "$(cat "$MANIFEST_FILE")" ]; then
    printf '{"ok":true,"action":"list","books":[],"count":0}\n'
    return 0
  fi

  local first=1 slug hash category date source
  printf '{"ok":true,"action":"list","books":['
  while IFS=$'\t' read -r slug hash category date source; do
    [ -z "$slug" ] && continue
    [ $first -eq 1 ] || printf ','
    printf '{"slug":"%s","category":"%s","imported":"%s","source":"%s","hash":"%s","search_folder":"%s"}' \
      "$(json_escape "$slug")" "$(json_escape "$category")" "$(json_escape "$date")" \
      "$(json_escape "$source")" "$(json_escape "$hash")" \
      "$(json_escape "$BOOKS_SUBDIR/$category/$slug/$BOOK_SOURCE_SUBDIR")"
    first=0
  done < "$MANIFEST_FILE"
  printf '],"count":%d}\n' "$(grep -c . "$MANIFEST_FILE")"
}

cmd_verify() {
  local problems=0 slug hash category date source folder actual
  if [ ! -f "$MANIFEST_FILE" ] || [ -z "$(cat "$MANIFEST_FILE")" ]; then
    printf '{"ok":true,"action":"verify","problems":[],"count":0}\n'
    return 0
  fi

  local out=""
  while IFS=$'\t' read -r slug hash category date source; do
    [ -z "$slug" ] && continue
    folder="$VAULT_DIR/$BOOKS_SUBDIR/$category/$slug/$BOOK_SOURCE_SUBDIR"
    if [ ! -d "$folder" ]; then
      problems=$((problems + 1))
      printf -v out '%s{"slug":"%s","problem":"folder_missing","path":"%s"},' \
        "$out" "$(json_escape "$slug")" "$(json_escape "$folder")"
      continue
    fi
    # The manifest stores the hash of the ORIGINAL file. For an imported
    # EPUB/TXT that is `original.<ext>`, not the extracted Markdown — hashing
    # the extraction would report drift on every book that was ever converted.
    actual="$(find "$folder" -maxdepth 1 -type f -name 'original.*' 2>/dev/null | head -1)"
    if [ -z "$actual" ]; then
      actual="$(find "$folder" -maxdepth 1 -type f ! -name '.import*' 2>/dev/null | head -1)"
    fi
    if [ -z "$actual" ]; then
      problems=$((problems + 1))
      printf -v out '%s{"slug":"%s","problem":"source_file_missing","path":"%s"},' \
        "$out" "$(json_escape "$slug")" "$(json_escape "$folder")"
      continue
    fi
    if [ "$(hash_file "$actual")" != "$hash" ]; then
      problems=$((problems + 1))
      printf -v out '%s{"slug":"%s","problem":"hash_drift","file":"%s"},' \
        "$out" "$(json_escape "$slug")" "$(json_escape "$actual")"
    fi
  done < "$MANIFEST_FILE"

  if [ "$problems" -gt 0 ]; then
    printf '{"ok":false,"action":"verify","problems":[%s],"count":%d,"hint":"re-run book_import.sh --book <path> --force, or remove <slug>"}\n' \
      "${out%,}" "$problems"
  else
    printf '{"ok":true,"action":"verify","problems":[],"count":0}\n'
  fi
}

cmd_remove() {
  local known row category folder full deleted="false"
  if [ -z "$TARGET_SLUG" ]; then
    printf '{"ok":false,"error":"slug_required","hint":"bash scripts/book_admin.sh remove <slug>"}\n'
    return 1
  fi
  [ -f "$MANIFEST_FILE" ] || {
    printf '{"ok":false,"error":"unknown_slug","slug":"%s"}\n' "$(json_escape "$TARGET_SLUG")"
    return 1
  }
  row="$(awk -F'\t' -v s="$TARGET_SLUG" '$1 == s { print; found=1 } END { exit !found }' "$MANIFEST_FILE")" || {
    printf '{"ok":false,"error":"unknown_slug","slug":"%s"}\n' "$(json_escape "$TARGET_SLUG")"
    return 1
  }
  category="$(printf '%s' "$row" | cut -f3)"
  folder="$BOOKS_SUBDIR/$category/$TARGET_SLUG"
  full="$VAULT_DIR/$folder"

  if [ "$DRY_RUN" = "true" ]; then
    printf '{"ok":true,"action":"dry_run","slug":"%s","would_forget":"%s","would_delete":%s}\n' \
      "$(json_escape "$TARGET_SLUG")" "$(json_escape "$folder")" \
      "$([ "$DELETE_DIR" = "true" ] && echo true || echo false)"
    return 0
  fi

  manifest_remove "$TARGET_SLUG"

  local deleted="false"
  if [ "$DELETE_DIR" = "true" ]; then
    if [ -d "$full" ]; then
      rm -rf "$full" && deleted="true"
    fi
  fi

  printf '{"ok":true,"action":"removed","slug":"%s","folder":"%s","deleted":%s,"note":"the embedding index still holds the old chunks; run enquire-mcp build-embeddings --vault <path> to drop them"}\n' \
    "$(json_escape "$TARGET_SLUG")" "$(json_escape "$folder")" "$deleted"
}

# --------------------------------------------------------------------------

[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --delete)  DELETE_DIR="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -*)
      print_help_and_exit ;;
    *)
      # First bare word after the command is the slug for `remove`.
      if [ "$CMD" = "remove" ] && [ -z "$TARGET_SLUG" ]; then
        TARGET_SLUG="$1"
        shift
      else
        print_help_and_exit
      fi
      ;;
  esac
done

case "$CMD" in
  status) ACTION="status" ;;
  list)   ACTION="list" ;;
  verify) ACTION="verify" ;;
  remove) ACTION="remove" ;;
  ""|"-h"|--help|help) print_help; exit 0 ;;
  *) print_help_and_exit ;;
esac

book_load_config
rc=$?
if [ $rc -eq 1 ]; then
  book_config_not_found_json
  exit 1
elif [ $rc -ne 0 ]; then
  exit 1
fi

MANIFEST_FILE="$BOOK_STATE_DIR/manifest.tsv"

case "$ACTION" in
  status) cmd_status ;;
  list)   cmd_list ;;
  verify) cmd_verify ;;
  remove) cmd_remove ;;
esac