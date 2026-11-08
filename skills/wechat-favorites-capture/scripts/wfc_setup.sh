#!/bin/bash
# wfc_setup.sh — first-run wizard and dependency installer for
# wechat-favorites-capture.
#
# ██ HUMAN ONLY ██
# `--init` and `--init --dry-run` read answers from /dev/tty and WRITE the
# user's config. An LLM must never run either: the user owns their config,
# and a prompt injected into the conversation must not be able to steer it.
# When the agent needs this skill configured, it tells the user to run this
# script themselves and relays the output.
#
#   bash scripts/wfc_setup.sh --init                # interactive wizard
#   bash scripts/wfc_setup.sh --init --dry-run      # preview only, writes nothing
#   bash scripts/wfc_setup.sh --detect              # report the environment
#   bash scripts/wfc_setup.sh --help
#
# The wizard does three things:
#   1. asks where to save the captured content (default: the vault's raw/)
#   2. makes sure the dependencies are actually there — python venv with
#      frida + pycryptodome, the wechat-favorites-viz skill, the article
#      scraper skill, opencli, Chrome
#   3. merges the answers into the shared ~/.mario-skills/.env, keeping a
#      timestamped backup of the previous file

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SKILL_DIR/scripts/wfc_env.sh"

VIZ_REPO="https://github.com/zhuyansen/wx-favorites-report.git"
VIZ_DIR_DEFAULT="$HOME/.claude/skills/wx-favorites-report"
SCRAPER_DIR_DEFAULT="$HOME/.claude/skills/wechat-article-scraper"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

# ask VAR "prompt" "default" — reads from /dev/tty so a piped script cannot
# accidentally answer the wizard.
ask() {
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

detect_favorite_db() {
  local c
  for c in "$HOME"/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/*/db_storage/favorite/favorite.db; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ensure_venv — create the decrypt virtualenv and install the two packages the
# decryption step needs. Prints the python path on stdout, diagnostics on stderr.
ensure_venv() {
  local venv="$1" pypath="$venv/bin/python"
  if [ -x "$pypath" ] && "$pypath" -c "import frida, Crypto" >/dev/null 2>&1; then
    printf '%s' "$pypath"
    return 0
  fi
  mkdir -p "$venv" 2>/dev/null || true
  if [ ! -x "$pypath" ]; then
    python3 -m venv "$venv" >&2 || {
      echo "  ✗ 无法创建 venv：$venv" >&2
      return 1
    }
  fi
  echo "  · 安装 frida / frida-tools / pycryptodome …" >&2
  if command -v uv >/dev/null 2>&1; then
    if ! uv pip install --python "$pypath" frida frida-tools pycryptodome >&2 2>&1; then
      "$pypath" -m pip install --quiet --upgrade pip >&2 2>&1
      "$pypath" -m pip install --quiet frida frida-tools pycryptodome >&2 2>&1
    fi
  else
    "$pypath" -m pip install --quiet --upgrade pip >&2 2>&1
    "$pypath" -m pip install --quiet frida frida-tools pycryptodome >&2 2>&1
  fi
  if "$pypath" -c "import frida, Crypto" >/dev/null 2>&1; then
    printf '%s' "$pypath"
    return 0
  fi
  echo "  ✗ 依赖安装失败，稍后手动执行：$pypath -m pip install frida frida-tools pycryptodome" >&2
  return 1
}

# ensure_viz_skill — the wechat-favorites-viz skill.
#
# It is two things to us: parse_favorites.py turns the decrypted database into
# favorites.json (export needs it), and generate_report.py renders the HTML
# dashboard (report needs it). parse_favorites.py is the one that decides
# whether the skill is installed at all.
ensure_viz_skill() {
  local dir="$1"
  if [ -f "$dir/scripts/parse_favorites.py" ]; then
    if [ ! -f "$dir/scripts/generate_report.py" ]; then
      echo "  ! $dir 有 parse_favorites.py 但缺 generate_report.py —— 报告步骤会跳过" >&2
    fi
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "  ✗ 没有 git，无法自动安装 wx-favorites-report" >&2
    return 1
  fi
  echo "  · 安装 wx-favorites-report → $dir" >&2
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true
  if [ -d "$dir" ]; then
    echo "  ✗ $dir 已存在但缺少 scripts/parse_favorites.py，请手动检查" >&2
    return 1
  fi
  git clone --depth 1 "$VIZ_REPO" "$dir" >&2 2>&1 || {
    echo "  ✗ clone 失败：$VIZ_REPO" >&2
    return 1
  }
  [ -f "$dir/scripts/parse_favorites.py" ]
}

# --------------------------------------------------------------------------
# --detect
# --------------------------------------------------------------------------

cmd_detect() {
  local p count=0 tmp

  echo "Obsidian vault："
  tmp="$(mktemp -t wfc-detect-XXXXXX)"
  detect_obsidian_vaults > "$tmp" 2>/dev/null || true
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    count=$((count + 1))
    if [ -d "$p" ]; then
      printf '  [%d] %s\n' "$count" "$p"
    else
      printf '  [%d] %s  (磁盘上不存在)\n' "$count" "$p"
    fi
  done < "$tmp"
  rm -f "$tmp"
  [ "$count" -eq 0 ] && echo "  没找到 obsidian.json，手动填路径"

  echo ""
  echo "微信收藏库："
  local db
  db="$(detect_favorite_db || true)"
  if [ -n "$db" ]; then
    echo "  $db"
  else
    echo "  未找到（微信需登录过并收藏过东西）"
  fi

  echo ""
  echo "依赖："
  if command -v python3 >/dev/null 2>&1; then
    printf '  python3          %s\n' "$(python3 -V 2>&1)"
  else
    printf '  python3          缺失\n'
  fi
  if command -v opencli >/dev/null 2>&1; then
    printf '  opencli          %s\n' "$(command -v opencli)"
    echo "                  还需要 Chrome 已登录 + OpenCLI 扩展已连接：opencli doctor"
  else
    printf '  opencli          缺失（抓正文必需）\n'
  fi
  if [ -d "/Applications/Google Chrome.app" ]; then
    echo "  Chrome           已安装"
  else
    echo "  Chrome           缺失（抓正文必需）"
  fi
  if [ -f "$SCRAPER_DIR_DEFAULT/scripts/scrape.py" ]; then
    printf '  article-scraper  %s\n' "$SCRAPER_DIR_DEFAULT"
  else
    printf '  article-scraper  缺失 → %s\n' "$SCRAPER_DIR_DEFAULT"
  fi
  if [ -f "$VIZ_DIR_DEFAULT/scripts/generate_report.py" ]; then
    printf '  wx-favorites-report %s\n' "$VIZ_DIR_DEFAULT"
  else
    printf '  wx-favorites-report 缺失 → %s\n' "$VIZ_DIR_DEFAULT"
  fi
}

# --------------------------------------------------------------------------
# --init
# --------------------------------------------------------------------------

cmd_init() {
  local dry_run="${1:-false}" target="${2:-user}"
  local target_file w_vault w_out w_set w_tier w_limit w_chunk w_delay w_tag w_state
  local w_db=""
  local detected_n tmp default_vault default_db

  if [ "$target" = "project" ]; then
    target_file="$WFC_ENV_PROJECT_FILE"
  else
    target_file="$WFC_ENV_HOME_FILE"
  fi

  # Prefill from the currently resolved config, so a re-run shows the real
  # values rather than the built-in defaults.
  wfc_resolve_all
  w_vault="$VAULT_DIR"; w_out="$WX_FAV_OUT_SUBDIR"; w_set="$WX_FAV_SET_SUBDIR"
  w_tier="$WX_FAV_TIER"; w_limit="$WX_FAV_LIMIT"; w_chunk="$WX_FAV_CHUNK"
  w_delay="$WX_FAV_DELAY"; w_tag="$WX_FAV_TAG"; w_state="$WX_FAV_STATE_DIR"

  default_vault="$w_vault"
  detected_n=0
  tmp="$(mktemp -t wfc-init-XXXXXX)"
  detect_obsidian_vaults > "$tmp" 2>/dev/null || true
  detected_n="$(grep -c . "$tmp" 2>/dev/null || echo 0)"
  if [ "$detected_n" -gt 1 ] 2>/dev/null; then
    echo "检测到多个 vault —— 输编号或直接粘路径：" >&2
    local n=0 p
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      n=$((n + 1))
      printf '  [%d] %s\n' "$n" "$p" >&2
    done < "$tmp"
  fi
  rm -f "$tmp"

  default_db="$(detect_favorite_db || true)"
  [ -n "$default_db" ] || default_db="$w_db"

  echo "" >&2
  echo "wechat-favorites-capture 配置 —— 写入 $target_file" >&2
  echo "" >&2

  ask w_vault "Vault 根目录" "$default_vault"
  ask w_out   "采集内容保存目录（相对 vault；可写绝对路径）" "$w_out"
  ask w_set   "该目录下的数据集子目录（留空 = 直接存在保存目录里）" "$w_set"
  ask w_tier  "默认抓取分层（T1=2024年起的AI内容 / T2=2024前的管理与理财 / T3=旧技术 / all）" "$w_tier"
  ask w_limit "默认最多抓几篇（0 = 不限）" "$w_limit"
  ask w_chunk "每块几篇（浏览器会话上限，建议 ≤6）" "$w_chunk"
  ask w_delay "每篇间隔秒数（微信风控，建议 15~20）" "$w_delay"
  ask w_tag   "写入 frontmatter 的 tag" "$w_tag"
  ask w_state "状态目录" "$w_state"
  ask w_db    "微信收藏库路径（留空 = 自动探测）" "$default_db"

  w_vault="$(wfc_expand_tilde "$w_vault")"
  w_state="$(wfc_expand_tilde "$w_state")"
  w_db="$(wfc_expand_tilde "$w_db")"

  # Strip trailing slashes so path joins stay clean.
  while :; do
    case "$w_out" in */) w_out="${w_out%/}" ;; *) break ;; esac
  done
  while :; do
    case "$w_set" in */) w_set="${w_set%/}" ;; *) break ;; esac
  done
  [ "$w_set" = "/" ] && w_set=""

  # --- preview ---
  if [ "$dry_run" = "true" ]; then
    {
      echo "Would merge into $target_file:"
      printf 'VAULT_DIR=%s\nWX_FAV_OUT_SUBDIR=%s\nWX_FAV_SET_SUBDIR=%s\nWX_FAV_TIER=%s\n' \
        "$w_vault" "$w_out" "$w_set" "$w_tier"
      printf 'WX_FAV_LIMIT=%s\nWX_FAV_CHUNK=%s\nWX_FAV_DELAY=%s\nWX_FAV_TAG=%s\n' \
        "$w_limit" "$w_chunk" "$w_delay" "$w_tag"
      printf 'WX_FAV_STATE_DIR=%s\nWX_FAV_DB=%s\n' "$w_state" "$w_db"
      echo
      echo "采集结果会落在：$w_vault/$w_out${w_set:+/$w_set}/articles/<分类>/"
      echo "Nothing was changed."
    } >&2
    return 0
  fi

  # --- dependencies ---
  echo "" >&2
  echo "依赖安装：" >&2
  local venv="$w_state/venv"
  ensure_venv "$venv" >/dev/null || true
  ensure_viz_skill "$VIZ_DIR_DEFAULT" || true
  if [ ! -f "$SCRAPER_DIR_DEFAULT/scripts/scrape.py" ]; then
    echo "  ✗ 缺少 wechat-article-scraper（抓正文必需）" >&2
    echo "    请把该 skill 放到 $SCRAPER_DIR_DEFAULT，或改用 WX_FAV_SCRAPER_SKILL 指定路径" >&2
  fi
  if ! command -v opencli >/dev/null 2>&1; then
    echo "  ✗ 缺少 opencli（抓正文必需）" >&2
  fi
  if [ ! -d "/Applications/Google Chrome.app" ]; then
    echo "  ✗ 缺少 Chrome（抓正文必需）" >&2
  fi
  echo "" >&2

  # --- write config ---
  mkdir -p "$(dirname "$target_file")"
  [ -f "$target_file" ] && cp -p "$target_file" "$target_file.bak.$(date +%Y%m%d%H%M%S)"

  # 合并写入：先剥掉本技能自己的键，再追加一个新块。文件里其它技能的键、
  # 用户自己的注释全部保留。
  #
  # VAULT_DIR 和 OPENCLI_BIN 是和别的技能共享的键。已经在文件里的值保持原样
  # —— 别把这个 skill 的向导当成有权改别人配置的入口。只有文件里没有时才写。
  merged="$(mktemp -t wfc-merge-XXXXXX)"
  if [ -f "$target_file" ]; then
    grep -vE '^(export[[:space:]]+)?(WX_FAV_OUT_SUBDIR|WX_FAV_SET_SUBDIR|WX_FAV_TIER|WX_FAV_LIMIT|WX_FAV_CHUNK|WX_FAV_DELAY|WX_FAV_TAG|WX_FAV_STATE_DIR|WX_FAV_DB|WX_FAV_VIZ_SKILL|WX_FAV_SCRAPER_SKILL)=' \
      "$target_file" > "$merged"
    # 这两个键如果文件里已经有了，就整行留着——不能既剥掉又写一份。
    # 注意不能写成 `env_get ... || grep ... && mv ...`：`||` 和 `&&` 同优先级
    # 从左往右结合，那样的写法在「键已存在」时反而会去 mv 一个不存在的临时文件。
    if ! env_get VAULT_DIR "$target_file" >/dev/null 2>&1; then
      grep -vE '^(export[[:space:]]+)?VAULT_DIR=' "$target_file" > "$merged.tmp" \
        && mv "$merged.tmp" "$merged"
    fi
    if ! env_get OPENCLI_BIN "$target_file" >/dev/null 2>&1; then
      grep -vE '^(export[[:space:]]+)?OPENCLI_BIN=' "$target_file" > "$merged.tmp" \
        && mv "$merged.tmp" "$merged"
    fi
  else
    printf '# mario-skills shared environment\n# Read by every skill. Never commit.\n\n' > "$merged"
  fi

  {
    printf '\n# --- wechat-favorites-capture --------------------------------------\n'
    env_get VAULT_DIR "$target_file" >/dev/null 2>&1 || printf 'VAULT_DIR=%s\n' "$w_vault"
    printf 'WX_FAV_OUT_SUBDIR=%s\n' "$w_out"
    printf 'WX_FAV_SET_SUBDIR=%s\n' "$w_set"
    printf 'WX_FAV_TIER=%s\n' "$w_tier"
    printf 'WX_FAV_LIMIT=%s\n' "$w_limit"
    printf 'WX_FAV_CHUNK=%s\n' "$w_chunk"
    printf 'WX_FAV_DELAY=%s\n' "$w_delay"
    printf 'WX_FAV_TAG=%s\n' "$w_tag"
    printf 'WX_FAV_STATE_DIR=%s\n' "$w_state"
    printf 'WX_FAV_DB=%s\n' "$w_db"
    env_get OPENCLI_BIN "$target_file" >/dev/null 2>&1 || printf 'OPENCLI_BIN=opencli\n'
  } >> "$merged"

  local action="config_written"
  if mv "$merged" "$target_file"; then
    chmod 600 "$target_file" 2>/dev/null
  else
    rm -f "$merged"
    action="config_write_failed"
  fi

  printf '{"ok":%s,"action":"%s","path":"%s","dataset_dir":"%s","keys":["VAULT_DIR","WX_FAV_OUT_SUBDIR","WX_FAV_SET_SUBDIR","WX_FAV_TIER","WX_FAV_LIMIT","WX_FAV_CHUNK","WX_FAV_DELAY","WX_FAV_TAG","WX_FAV_STATE_DIR","WX_FAV_DB"],"note":"merged in place; other skills keys and your comments survive, and a .bak.<timestamp> copy of the previous file sits alongside"}\n' \
    "$([ "$action" = "config_written" ] && echo true || echo false)" \
    "$action" "$target_file" "$w_vault/$w_out${w_set:+/$w_set}"
}

# --------------------------------------------------------------------------
# entry
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
wfc_setup.sh — wechat-favorites-capture 首次配置向导

用法：
  bash scripts/wfc_setup.sh --init                交互式向导（人跑）
  bash scripts/wfc_setup.sh --init --dry-run      预演，什么都不写
  bash scripts/wfc_setup.sh --init --target project  写到 <cwd>/.mario-skills/.env
  bash scripts/wfc_setup.sh --detect              列出本机 vault / 依赖状态
  bash scripts/wfc_setup.sh --help

注意：--init 会写你的配置，必须由你本人执行。
EOF
}

case "${1:-}" in
  --init)
    shift
    DRY="false"
    TARGET="user"
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) DRY="true" ;;
        --target) shift; TARGET="${1:-user}" ;;
        --target=*) TARGET="${1#--target=}" ;;
      esac
      shift
    done
    cmd_init "$DRY" "$TARGET"
    ;;
  --detect)
    cmd_detect
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
