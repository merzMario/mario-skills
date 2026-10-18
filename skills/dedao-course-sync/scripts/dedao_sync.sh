#!/bin/bash
# dedao_sync.sh — 得到专栏增量同步的入口。配置在这里解析，抓取在 dedao_sync.py。
#
# 人工，一次：
#   bash scripts/dedao_sync.sh --init
#
# 日常（Agent / shell）：
#   bash scripts/dedao_sync.sh fetch --course all --count 20
#   bash scripts/dedao_sync.sh list  --course jingxuan --dry-run
#
# 配置解析 — 优先级从高到低：
#   1. process environment            VAULT_DIR=/x bash dedao_sync.sh …
#   2. <cwd>/.mario-skills/.env       项目级，所有 mario 技能共用
#   3. ~/.mario-skills/.env          用户级，所有 mario 技能共用
#   4. 内置默认值
#
# .mario-skills/.env 是唯一的配置文件，也是整个 marketplace 共用的约定：
# 仓库里每个技能都读同样这两个文件。VAULT_DIR 与 diary-writer、
# book-enquire-reader 同名同义，写一次三个技能都看到。
#
# 值是「解析」出来的，不是 source 的。.env 里可能有 $(...) 或 ;，
# source 它等于把凭据文件变成任意代码执行入口。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
PY_SCRIPT="$SCRIPT_DIR/dedao_sync.py"

# --------------------------------------------------------------------------
# 共享 .env（mario-skills 约定）
# --------------------------------------------------------------------------

# 可被覆盖，方便测试和特殊布局
ENV_HOME_FILE="${MARIO_SKILLS_ENV:-$HOME/.mario-skills/.env}"
ENV_PROJECT_FILE="${MARIO_SKILLS_PROJECT_ENV:-$PWD/.mario-skills/.env}"

DEDAO_DEFAULT_OUT_SUBDIR="raw/Courses-GetIt"
DEDAO_DEFAULT_SESSION="dedao-sync"
DEDAO_DEFAULT_COUNT="20"
DEDAO_DEFAULT_STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dedao-course-sync"
DEDAO_DEFAULT_OPENCLI_BIN="opencli"

# 在任何变量被重新赋值之前，把继承来的进程环境快照下来。
# resolve_setting 只读这份快照，绝不读它自己刚写进去的值 —— 否则第二次调用
# 会把第一次的结果当成 process.env。
SNAP_VAULT_DIR="${VAULT_DIR-}"
SNAP_OUT_SUBDIR="${DEDAO_OUT_SUBDIR-}"
SNAP_SESSION="${DEDAO_SESSION-}"
SNAP_COUNT="${DEDAO_COUNT-}"
SNAP_STATE_DIR="${DEDAO_STATE_DIR-}"
SNAP_OPENCLI_BIN="${OPENCLI_BIN-}"

# 打印 KEY 的值；文件里最后一个定义生效。文件不存在或没有该键时返回 1，
# 调用方因此可以 `elif val=$(env_get …)` 串起多层。
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

# 按优先级链解析 KEY，记录哪一层应答。
# 结果写进 BOOK_… 风格的记录串，而不是 RESOLVED_<KEY> 变量 —— 回读那些
# 变量需要间接展开，而动态变量查找正是这个技能最该避开的东西。
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
  else
    val="$default"
    src="built-in default"
  fi

  RECORDS="${RECORDS}${key}"$'\t'"${val}"$'\t'"${src}"$'\n'
}

expand_tilde() {
  local v="$1"
  case "$v" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${v#\~/}" ;;
    *) printf '%s' "$v" ;;
  esac
}

# 每个键独立解析：只设 VAULT_DIR 不会把其余五个打回默认值。
# 记录按下面这个顺序发出，--config-info 的渲染器按位置顺序读。
#   VAULT_DIR DEDAO_OUT_SUBDIR DEDAO_SESSION DEDAO_COUNT DEDAO_STATE_DIR OPENCLI_BIN
resolve_all() {
  RECORDS=""

  resolve_setting VAULT_DIR          "$SNAP_VAULT_DIR"    "$HOME/Documents/Obsidian"
  resolve_setting DEDAO_OUT_SUBDIR   "$SNAP_OUT_SUBDIR"   "$DEDAO_DEFAULT_OUT_SUBDIR"
  resolve_setting DEDAO_SESSION      "$SNAP_SESSION"      "$DEDAO_DEFAULT_SESSION"
  resolve_setting DEDAO_COUNT        "$SNAP_COUNT"        "$DEDAO_DEFAULT_COUNT"
  resolve_setting DEDAO_STATE_DIR    "$SNAP_STATE_DIR"    "$DEDAO_DEFAULT_STATE_DIR"
  resolve_setting OPENCLI_BIN        "$SNAP_OPENCLI_BIN"  "$DEDAO_DEFAULT_OPENCLI_BIN"

  local rec
  while IFS=$'\t' read -r rec_key rec rec_src; do
    [ -n "$rec_key" ] || continue
    case "$rec_key" in
      VAULT_DIR)        VAULT_DIR="$(expand_tilde "$rec")"; VAULT_SOURCE="$rec_src" ;;
      DEDAO_STATE_DIR)  DEDAO_STATE_DIR="$(expand_tilde "$rec")" ;;
      DEDAO_OUT_SUBDIR) DEDAO_OUT_SUBDIR="$rec" ;;
      DEDAO_SESSION)    DEDAO_SESSION="$rec" ;;
      DEDAO_COUNT)      DEDAO_COUNT="$rec" ;;
      OPENCLI_BIN)      OPENCLI_BIN="$rec" ;;
    esac
  done <<EOF
$RECORDS
EOF
}

# 配置缺失时的 JSON 错误。列出**每一个**找过的位置，好让 Agent 原样转述
# searched 数组，而不是自己复述成一句没用的「没配置」。
config_not_found_json() {
  printf '{"ok":false,"error":"config_not_found","searched":["process.env","%s","%s"],"hint":"run: bash scripts/dedao_sync.sh --init"}\n' \
    "$ENV_PROJECT_FILE" "$ENV_HOME_FILE"
}

load_config() {
  resolve_all

  if [ "$VAULT_SOURCE" = "built-in default" ]; then
    return 1
  fi

  if [ ! -d "$VAULT_DIR" ]; then
    printf '{"ok":false,"error":"vault_dir_not_found","path":"%s","hint":"run --config-info to see which layer supplied it; an iCloud folder rename leaves the old path behind"}\n' \
      "$VAULT_DIR" >&2
    return 2
  fi

  mkdir -p "$DEDAO_STATE_DIR" 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------
# 输出
# --------------------------------------------------------------------------

print_help() {
  cat <<'EOF'
dedao_sync.sh — 得到专栏（得到精选 / 得到头条）增量同步

用法：
  bash scripts/dedao_sync.sh fetch --course all [--count 20] [--dry-run]
  bash scripts/dedao_sync.sh list  --course jingxuan [--count 20]

抓取参数：
  --course <id>   jingxuan | toutiao | all（默认 all）
  --count <n>     本次要抓的**新**篇数，默认取 DEDAO_COUNT（20）
                  不够就往回翻页直到凑满或翻完，不是「最新 N 条里没抓过的」
  --dry-run       只列出待抓清单，**不写任何文件**。仍需浏览器（列表接口必须调）

配置（人跑，不要在 LLM 调用里执行）：
  --init                首次配置向导，写 ~/.mario-skills/.env
  --init --project      写 <cwd>/.mario-skills/.env
  --init --dry-run      预演向导，什么都不写
  --detect              列出本机 Obsidian vault 和 opencli 状态

检查：
  --config-info         打印每个解析出的值、它来自哪一层、以及完整搜索路径
  --config-info --json  同上，机读

其它：
  --json                stdout 输出单个 JSON 回执（默认也是 JSON，人读信息走 stderr）
  --help, --version

退出码：
  0  成功（list 成功，或 fetch 全部成功 / 无新内容）
  1  有任何一篇抓取失败，或运行期错误
  2  配置缺失、vault 不存在、参数错误
EOF
}

# --------------------------------------------------------------------------
# --init 向导（人跑）
# --------------------------------------------------------------------------

ask() {
  # ask VAR "prompt" "default"
  # 优先读 /dev/tty，这样管道喂进来的内容不会偷偷应答向导。
  # 这里必须探测而不能用 `[ -r /dev/tty ]`：在 cron 和部分 CI 沙箱里
  # /dev/tty 可读但不可用，read 会报 "Device not configured"。
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

cmd_detect() {
  local json="" j tmp count=0 p
  for j in \
    "$HOME/Library/Application Support/obsidian/obsidian.json" \
    "$HOME/.config/obsidian/obsidian.json" \
    "${APPDATA:-}/obsidian/obsidian.json"; do
    [ -f "$j" ] && { json="$j"; break; }
  done

  echo "Obsidian vault："
  if [ -z "$json" ]; then
    echo "  没找到 obsidian.json，手动填路径"
  else
    tmp="$(mktemp -t dedao-detect-XXXXXX)"
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
    echo "  共 $count 个"
  fi

  echo ""
  echo "opencli（浏览器桥）："
  if command -v "$OPENCLI_BIN" >/dev/null 2>&1; then
    printf '  已安装 %s\n' "$(command -v "$OPENCLI_BIN")"
    echo ""
    echo "  还需要 Chrome 已登录得到 + OpenCLI 扩展已连接。用下面确认："
    echo "    $OPENCLI_BIN doctor"
  else
    printf '  ❌ 未找到 %s —— 抓取无法进行\n' "$OPENCLI_BIN"
  fi
}

cmd_init() {
  local dry_run="${1:-false}" target="${2:-user}"
  local target_file w_vault w_out w_session w_count w_state w_bin
  local merged detected detected_n tmp default_vault

  if [ "$target" = "project" ]; then
    target_file="$ENV_PROJECT_FILE"
  else
    target_file="$ENV_HOME_FILE"
  fi

  # 用当前解析出的值预填，重跑一次看到的是你的真实配置而不是内置默认值
  resolve_all
  w_vault="$VAULT_DIR"
  w_out="$DEDAO_OUT_SUBDIR"
  w_session="$DEDAO_SESSION"
  w_count="$DEDAO_COUNT"
  w_state="$DEDAO_STATE_DIR"
  w_bin="$OPENCLI_BIN"

  detected_n=0
  tmp="$(mktemp -t dedao-init-XXXXXX)"
  detect_obsidian_vaults > "$tmp" 2>/dev/null || true
  detected_n="$(grep -c . "$tmp" 2>/dev/null || echo 0)"
  default_vault="$w_vault"
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

  echo "" >&2
  echo "dedao-course-sync 配置 —— 写入 $target_file" >&2
  echo "" >&2

  ask w_vault    "Vault 根目录"              "$default_vault"
  ask w_out      "产出目录（相对 vault）"    "$w_out"
  ask w_session  "opencli 会话名"            "$w_session"
  ask w_count    "默认批量（每轮新篇数）"    "$w_count"
  ask w_state    "状态目录（失败清单）"      "$w_state"
  ask w_bin      "opencli 可执行文件"        "$w_bin"

  w_vault="$(expand_tilde "$w_vault")"
  w_state="$(expand_tilde "$w_state")"

  if [ "$dry_run" = "true" ]; then
    {
      echo "Would merge into $target_file:"
      printf 'VAULT_DIR=%s\nDEDAO_OUT_SUBDIR=%s\nDEDAO_SESSION=%s\n' "$w_vault" "$w_out" "$w_session"
      printf 'DEDAO_COUNT=%s\nDEDAO_STATE_DIR=%s\nOPENCLI_BIN=%s\n' "$w_count" "$w_state" "$w_bin"
      echo
      echo "Nothing was changed."
    } >&2
    return 0
  fi

  mkdir -p "$(dirname "$target_file")"
  [ -f "$target_file" ] && cp -p "$target_file" "$target_file.bak.$(date +%Y%m%d%H%M%S)"

  # 合并写入：先剥掉本技能自己的键，再追加一个新块。文件里其它技能的键、
  # 用户自己的注释全部保留。
  merged="$(mktemp -t dedao-merge-XXXXXX)"
  if [ -f "$target_file" ]; then
    grep -vE '^(export[[:space:]]+)?(VAULT_DIR|DEDAO_OUT_SUBDIR|DEDAO_SESSION|DEDAO_COUNT|DEDAO_STATE_DIR|OPENCLI_BIN)=' \
      "$target_file" > "$merged"
  else
    printf '# mario-skills shared environment\n# Read by every skill. Never commit.\n\n' > "$merged"
  fi

  {
    printf '\n# --- dedao-course-sync -------------------------------------------\n'
    printf 'VAULT_DIR=%s\n' "$w_vault"
    printf 'DEDAO_OUT_SUBDIR=%s\n' "$w_out"
    printf 'DEDAO_SESSION=%s\n' "$w_session"
    printf 'DEDAO_COUNT=%s\n' "$w_count"
    printf 'DEDAO_STATE_DIR=%s\n' "$w_state"
    printf 'OPENCLI_BIN=%s\n' "$w_bin"
  } >> "$merged"

  local action="config_written"
  if mv "$merged" "$target_file"; then
    chmod 600 "$target_file" 2>/dev/null
  else
    rm -f "$merged"
    action="config_write_failed"
  fi

  printf '{"ok":%s,"action":"%s","path":"%s","keys":["VAULT_DIR","DEDAO_OUT_SUBDIR","DEDAO_SESSION","DEDAO_COUNT","DEDAO_STATE_DIR","OPENCLI_BIN"],"note":"merged in place; other skills keys and your comments survive, and a .bak.<timestamp> copy of the previous file sits alongside"}\n' \
    "$([ "$action" = "config_written" ] && echo true || echo false)" \
    "$action" "$target_file"
}

# --------------------------------------------------------------------------
# --config-info
# --------------------------------------------------------------------------

searched_json() {
  local sp="$1"
  if [ "$sp" = "process.env" ]; then
    printf '{"path":"%s","source":"env","status":"present"}' "$sp"
  elif [ -f "$sp" ]; then
    printf '{"path":"%s","source":"file","status":"found"}' "$sp"
  else
    printf '{"path":"%s","source":"file","status":"absent"}' "$sp"
  fi
}

cmd_config_info() {
  local as_json="${1:-false}" rec_key rec_val rec_src mark sp
  local sep=""

  load_config
  local rc=$?
  if [ $rc -ne 0 ]; then
    [ "$rc" -eq 1 ] && [ "$as_json" = "true" ] && config_not_found_json
    return $rc
  fi

  if [ "$as_json" = "true" ]; then
    printf '{"ok":true,"settings":{'
    while IFS=$'\t' read -r rec_key rec_val rec_src; do
      [ -n "$rec_key" ] || continue
      printf '%s"%s":{"value":"%s","source":"%s"}' "$sep" "$rec_key" "$rec_val" "$rec_src"
      sep=","
    done <<EOF
$RECORDS
EOF
    printf '},"searched":['
    sep=""
    while IFS= read -r sp; do
      printf '%s%s' "$sep" "$(searched_json "$sp")"
      sep=","
    done <<EOF
process.env
$ENV_PROJECT_FILE
$ENV_HOME_FILE
EOF
    printf ']}\n'
    return 0
  fi

  echo "dedao-course-sync — 已解析配置"
  echo ""
  while IFS=$'\t' read -r rec_key rec_val rec_src; do
    [ -n "$rec_key" ] || continue
    printf '  %-20s %s\n' "$rec_key" "${rec_val:-(空)}"
  done <<EOF
$RECORDS
EOF
  echo ""
  echo "来源（优先级从高到低）："
  while IFS=$'\t' read -r rec_key rec_val rec_src; do
    [ -n "$rec_key" ] || continue
    printf '  %-20s %s\n' "$rec_key" "$rec_src"
  done <<EOF
$RECORDS
EOF
  echo ""
  echo "搜索路径："
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
$ENV_PROJECT_FILE
$ENV_HOME_FILE
EOF
}

# --------------------------------------------------------------------------
# 参数
# --------------------------------------------------------------------------

CMD=""
COURSE="all"
COUNT=""
DRY_RUN="false"
AS_JSON="false"
INIT_REQUESTED="false"
INIT_TARGET="user"
INIT_DRY_RUN="false"
DETECT_REQUESTED="false"
CONFIG_INFO="false"

while [ $# -gt 0 ]; do
  case "$1" in
    list|fetch)  CMD="$1"; shift ;;
    --course)    COURSE="${2:-}"; shift 2 ;;
    --course=*)  COURSE="${1#--course=}"; shift ;;
    --count)     COUNT="${2:-}"; shift 2 ;;
    --count=*)   COUNT="${1#--count=}"; shift ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    --json)      AS_JSON="true"; shift ;;
    --init)      INIT_REQUESTED="true"; shift ;;
    --init-dry-run) INIT_REQUESTED="true"; INIT_DRY_RUN="true"; shift ;;
    --project)   INIT_TARGET="project"; shift ;;
    --detect)    DETECT_REQUESTED="true"; shift ;;
    --config-info) CONFIG_INFO="true"; shift ;;
    --help|-h)   print_help; exit 0 ;;
    --version|-V) echo "dedao_sync.sh — part of dedao-course-sync"; exit 0 ;;
    -*)          printf '❌ 未知参数: %s\n用 --help 看用法。\n' "$1" >&2; exit 1 ;;
    *)
      printf '❌ 未知参数: %s\n用 --help 看用法。\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ "$INIT_REQUESTED" = "true" ]; then
  # --init --dry-run 和 --init-dry-run 等价，前者更好记
  [ "$INIT_DRY_RUN" = "true" ] || { [ "$DRY_RUN" = "true" ] && INIT_DRY_RUN="true"; }
  # 解析一次配置，好让 detect/向导用得上当前值
  resolve_all
  cmd_init "$INIT_DRY_RUN" "$INIT_TARGET"
  exit $?
fi

if [ "$DETECT_REQUESTED" = "true" ]; then
  resolve_all
  cmd_detect
  exit 0
fi

if [ "$CONFIG_INFO" = "true" ]; then
  cmd_config_info "$AS_JSON"
  exit $?
fi

if [ -z "$CMD" ]; then
  printf '{"ok":false,"error":"cmd_required","hint":"pass list or fetch; see --help"}\n'
  exit 2
fi

load_config
rc=$?
if [ $rc -eq 1 ]; then
  config_not_found_json
  echo "" >&2
  echo "任何一层都没提供 VAULT_DIR。跑一次 --init，或者临时指定：" >&2
  echo "  VAULT_DIR=/path/to/vault bash scripts/dedao_sync.sh $CMD …" >&2
  exit 2
elif [ $rc -ne 0 ]; then
  exit 2
fi

if [ -z "$COUNT" ]; then
  COUNT="$DEDAO_COUNT"
fi

if ! printf '%s' "$COUNT" | grep -qE '^[0-9]+$'; then
  printf '{"ok":false,"error":"bad_count","value":"%s","hint":"--count 必须是正整数"}\n' "$(printf '%s' "$COUNT" | tr '\n' ' ')"
  exit 2
fi

if ! command -v "$OPENCLI_BIN" >/dev/null 2>&1; then
  printf '{"ok":false,"error":"opencli_not_found","bin":"%s","hint":"抓取依赖浏览器桥；装好 opencli 并确认它不在 PATH 之外"}\n' \
    "$(printf '%s' "$OPENCLI_BIN" | tr '\n' ' ')"
  exit 2
fi

# 配置以环境变量交给 Python 内核，内核不再自己解析。
# 数组而非字符串插值，避免未加引号的输入被当成 shell 拆开。
args=("$CMD" --course "$COURSE" --count "$COUNT")
[ "$DRY_RUN" = "true" ] && args+=(--dry-run)

DEDAO_VAULT="$VAULT_DIR" \
DEDAO_OUT_SUBDIR="$DEDAO_OUT_SUBDIR" \
DEDAO_SESSION="$DEDAO_SESSION" \
DEDAO_STATE_DIR="$DEDAO_STATE_DIR" \
OPENCLI_BIN="$OPENCLI_BIN" \
  python3 "$PY_SCRIPT" "${args[@]}"
exit $?
