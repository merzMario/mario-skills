#!/bin/bash
# wfc_doctor.sh — dependency and readiness preflight for wechat-favorites-capture.
#
# Agent-runnable: it only reads state and prints a JSON receipt. It never
# installs anything, never writes config, and never touches the WeChat
# database. Run it before any capture so a missing dependency surfaces as a
# precise list rather than a traceback three steps into the pipeline.
#
#   bash scripts/wfc_doctor.sh            # human-readable
#   bash scripts/wfc_doctor.sh --json     # machine-readable (default for agents)
#
# Exit codes:
#   0  every REQUIRED check passed
#   1  at least one required check failed
#   2  config missing (VAULT_DIR unset) — nothing else was checked

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SKILL_DIR/scripts/wfc_env.sh"

# 解析一次，让后面的脚本能直接读到带默认值的变量
wfc_resolve_all

FMT="text"
[ "${1:-}" = "--json" ] && FMT="json"

# --- check accumulators (bash 3.2: no arrays, so we accumulate strings) ------
CHECKS=""
SEP=""
OK_COUNT=0
FAIL_COUNT=0
MISSING_REQ=""
MISSING_OPT=""

# add_check ID NAME OK DETAIL FIX REQUIRED(1/0)
add_check() {
  local id="$1" name="$2" ok="$3" detail="$4" fix="$5" req="$6"
  local flag
  if [ "$ok" = "1" ]; then flag=true; OK_COUNT=$((OK_COUNT + 1)); else flag=false; FAIL_COUNT=$((FAIL_COUNT + 1)); fi

  if [ "$flag" = "false" ]; then
    if [ "$req" = "1" ]; then
      MISSING_REQ="${MISSING_REQ}${SEP}\"$(wfc_json_escape "$id")\""
    else
      MISSING_OPT="${MISSING_OPT}${SEP}\"$(wfc_json_escape "$id")\""
    fi
    SEP=","
  fi

  CHECKS="${CHECKS}${CHECKS:+,}{\"id\":\"$(wfc_json_escape "$id")\",\"name\":\"$(wfc_json_escape "$name")\",\"ok\":${flag},\"required\":$([ "$req" = "1" ] && echo true || echo false),\"detail\":\"$(wfc_json_escape "$detail")\",\"fix\":\"$(wfc_json_escape "$fix")\"}"
}

# find_first_existing CANDIDATE...  -> prints the first path that exists
find_first_existing() {
  local c
  for c in "$@"; do
    [ -e "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# --- config -----------------------------------------------------------------

wfc_resolve_all

if [ "$VAULT_DIR_SOURCE" = "built-in default" ]; then
  if [ "$FMT" = "json" ]; then
    wfc_config_not_found_json
  else
    echo "✗ 配置缺失：VAULT_DIR 未设置。"
    echo ""
    echo "在终端里跑一次向导（这一步必须由人执行）："
    echo "  bash $SKILL_DIR/scripts/wfc_setup.sh --init"
  fi
  exit 2
fi

# --- dependency locations ---------------------------------------------------

VIZ_SKILL="$WX_FAV_VIZ_SKILL"
if [ -z "$VIZ_SKILL" ]; then
  VIZ_SKILL="$(find_first_existing \
    "$HOME/.claude/skills/wx-favorites-report" \
    "$HOME/.claude/skills/wechat-favorites-viz" \
    "$HOME/.claude/skills/wx-favorites-viz" || true)"
fi

SCRAPER_SKILL="$WX_FAV_SCRAPER_SKILL"
if [ -z "$SCRAPER_SKILL" ]; then
  SCRAPER_SKILL="$(find_first_existing \
    "$HOME/.claude/skills/wechat-article-scraper" \
    "$HOME/.claude/skills/wechat-article-scrap" || true)"
fi

VENV_DIR="${WX_FAV_STATE_DIR}/venv"
VENV_PY="$VENV_DIR/bin/python"

# --- checks -----------------------------------------------------------------

# 1. system python3
if command -v python3 >/dev/null 2>&1; then
  add_check python3 "系统 Python 3" 1 "$(python3 -V 2>&1)" "" 1
else
  add_check python3 "系统 Python 3" 0 "未找到 python3" "安装 Python 3.9+（macOS: brew install python3）" 1
fi

# 2. skill venv with frida + pycryptodome
if [ -x "$VENV_PY" ]; then
  if "$VENV_PY" -c "import frida" >/dev/null 2>&1 && "$VENV_PY" -c "import Crypto" >/dev/null 2>&1; then
    add_check venv "解密虚拟环境（frida + pycryptodome）" 1 "$VENV_PY" "" 0
  else
    add_check venv "解密虚拟环境（frida + pycryptodome）" 0 "venv 存在但缺 frida 或 pycryptodome——只影响 export（解密）这一步，classify / scrape 不需要" "bash scripts/wfc_setup.sh --init 会补装" 0
  fi
else
  add_check venv "解密虚拟环境（frida + pycryptodome）" 0 "未创建（$VENV_PY）——只影响 export（解密）这一步，classify / scrape 不需要" "bash scripts/wfc_setup.sh --init 会创建并安装依赖" 0
fi

# 3. WeChat favorite.db
FAV_DB="$WX_FAV_DB"
if [ -z "$FAV_DB" ]; then
  for c in "$HOME"/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/*/db_storage/favorite/favorite.db; do
    if [ -f "$c" ]; then FAV_DB="$c"; break; fi
  done
fi
if [ -n "$FAV_DB" ] && [ -f "$FAV_DB" ]; then
  add_check wechat_db "微信收藏库 favorite.db" 1 "$FAV_DB" "" 1
else
  add_check wechat_db "微信收藏库 favorite.db" 0 "未找到（微信需至少登录过一次并收藏过东西）" "登录微信 Mac 客户端后重跑；或用 WX_FAV_DB 指定路径" 1
fi

# 4. wechat-favorites-viz skill (report generator)
if [ -n "$VIZ_SKILL" ] && [ -d "$VIZ_SKILL" ]; then
  if [ -f "$VIZ_SKILL/scripts/generate_report.py" ]; then
    add_check viz_skill "wx-favorites-report（解密解析 + 可视化报告）" 1 "$VIZ_SKILL" "" 1
  else
    add_check viz_skill "wx-favorites-report（解密解析 + 可视化报告）" 0 "$VIZ_SKILL 缺少 scripts/parse_favorites.py" "bash scripts/wfc_setup.sh --init 会重装" 1
  fi
else
  add_check viz_skill "wx-favorites-report（解密解析 + 可视化报告）" 0 "未安装" "bash scripts/wfc_setup.sh --init 会 clone github.com/zhuyansen/wx-favorites-report" 1
fi

# 5. wechat-article-scraper skill (required for the article bodies)
if [ -n "$SCRAPER_SKILL" ] && [ -f "$SCRAPER_SKILL/scripts/scrape.py" ]; then
  add_check scraper_skill "wechat-article-scraper（正文抓取）" 1 "$SCRAPER_SKILL" "" 1
else
  add_check scraper_skill "wechat-article-scraper（正文抓取）" 0 "未安装或缺少 scripts/scrape.py" "把该 skill 放进 ~/.claude/skills/，或用 WX_FAV_SCRAPER_SKILL 指定路径" 1
fi

# 6. opencli (browser bridge)
if command -v "$OPENCLI_BIN" >/dev/null 2>&1; then
  add_check opencli "opencli（浏览器桥）" 1 "$(command -v "$OPENCLI_BIN")" "" 1
else
  add_check opencli "opencli（浏览器桥）" 0 "未找到 $OPENCLI_BIN" "安装 opencli 并确认扩展已连上：$OPENCLI_BIN doctor" 1
fi

# 7. Chrome
if [ -d "/Applications/Google Chrome.app" ] || [ -d "/Applications/Chromium.app" ]; then
  add_check chrome "Chrome / Chromium" 1 "已安装" "" 1
else
  add_check chrome "Chrome / Chromium" 0 "未安装" "抓取正文需要真实浏览器（微信页有 poc_token 校验）" 1
fi

# 8. vault writable
if [ -d "$VAULT_DIR" ] && [ -w "$VAULT_DIR" ]; then
  add_check vault "Vault 目录可写" 1 "$VAULT_DIR" "" 1
else
  add_check vault "Vault 目录可写" 0 "$VAULT_DIR 不可写或不存在" "用 --config-info 检查 VAULT_DIR" 1
fi

# 9. dataset dir creatable
DATASET_DIR="$(wfc_dataset_dir)"
if [ -d "$DATASET_DIR" ] && [ -w "$DATASET_DIR" ]; then
  add_check dataset_dir "采集目录可写" 1 "$DATASET_DIR" "" 1
elif mkdir -p "$DATASET_DIR" 2>/dev/null; then
  add_check dataset_dir "采集目录可写" 1 "$DATASET_DIR（本次已创建）" "" 1
else
  add_check dataset_dir "采集目录可写" 0 "无法创建 $DATASET_DIR" "检查 WX_FAV_OUT_SUBDIR / WX_FAV_SET_SUBDIR" 1
fi

# --- render -----------------------------------------------------------------

if [ "$FMT" = "json" ]; then
  overall="true"
  [ -n "$MISSING_REQ" ] && overall="false"
  printf '{"ok":%s,"checks":[%s],"missing_required":[%s],"missing_optional":[%s],"paths":{"vault":"%s","dataset_dir":"%s","articles_dir":"%s","state_dir":"%s","viz_skill":"%s","scraper_skill":"%s","venv":"%s","wechat_db":"%s"}}\n' \
    "$overall" "$CHECKS" "$MISSING_REQ" "$MISSING_OPT" \
    "$(wfc_json_escape "$VAULT_DIR")" \
    "$(wfc_json_escape "$DATASET_DIR")" \
    "$(wfc_json_escape "$(wfc_articles_dir)")" \
    "$(wfc_json_escape "$WX_FAV_STATE_DIR")" \
    "$(wfc_json_escape "$VIZ_SKILL")" \
    "$(wfc_json_escape "$SCRAPER_SKILL")" \
    "$(wfc_json_escape "$VENV_PY")" \
    "$(wfc_json_escape "$FAV_DB")"
  [ -n "$MISSING_REQ" ] && exit 1
  exit 0
fi

echo "wechat-favorites-capture — 体检"
echo ""
echo "检查项："
echo "  python3          : $(command -v python3 >/dev/null 2>&1 && echo OK || echo MISSING)"
echo "  解密 venv        : $([ -x "$VENV_PY" ] && echo OK || echo MISSING)  $VENV_PY"
echo "  微信收藏库       : $([ -n "$FAV_DB" ] && [ -f "$FAV_DB" ] && echo OK || echo MISSING)"
echo "  wx-favorites-report : $([ -n "$VIZ_SKILL" ] && [ -d "$VIZ_SKILL" ] && echo OK || echo MISSING)"
echo "  article-scraper  : $([ -n "$SCRAPER_SKILL" ] && [ -f "$SCRAPER_SKILL/scripts/scrape.py" ] && echo OK || echo MISSING)"
echo "  opencli          : $(command -v "$OPENCLI_BIN" >/dev/null 2>&1 && echo OK || echo MISSING)"
echo "  Chrome           : $([ -d "/Applications/Google Chrome.app" ] && echo OK || echo MISSING)"
echo "  Vault            : $([ -w "$VAULT_DIR" ] && echo OK || echo MISSING)  $VAULT_DIR"
echo "  采集目录         : $([ -w "$DATASET_DIR" ] && echo OK || echo MISSING)  $DATASET_DIR"
echo ""
if [ -n "$MISSING_REQ" ]; then
  echo "缺少必需依赖。先跑一次向导（人执行）："
  echo "  bash $SKILL_DIR/scripts/wfc_setup.sh --init"
  exit 1
fi
echo "全部就绪。"
exit 0
