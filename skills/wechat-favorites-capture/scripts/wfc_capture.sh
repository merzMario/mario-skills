#!/bin/bash
# wfc_capture.sh — the capture pipeline for wechat-favorites-capture.
#
#   export    decrypt the WeChat favorite DB  → favorites.json
#   classify  bucket the favorites            → classified.json + urls/*.txt
#   scrape    pull the article bodies         → <dataset>/articles/<category>/
#   report    render the HTML dashboard       → report.html
#   all       export → classify → scrape → report
#   doctor    dependency preflight
#   config-info  show the resolved configuration
#
# Every command prints one JSON receipt on stdout. Progress and human
# commentary go to stderr, so `wfc_capture.sh classify | jq` always works.
#
# Exit codes:
#   0  success
#   1  the step failed (details in the receipt)
#   2  configuration missing, or a bad argument

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SKILL_DIR/scripts/wfc_env.sh"

# 解析一次，让后面的脚本能直接读到带默认值的变量
wfc_resolve_all

VENV_PY="${WX_FAV_STATE_DIR}/venv/bin/python"

# --------------------------------------------------------------------------
# shared helpers
# --------------------------------------------------------------------------

err() { printf '%s\n' "$*" >&2; }

die() {
  # die JSON_RECEIPT
  printf '%s\n' "$1"
  exit "${2:-2}"
}

need_config() {
  wfc_load_config
  local rc=$?
  if [ $rc -eq 1 ]; then
    wfc_config_not_found_json
    exit 2
  elif [ $rc -ne 0 ]; then
    exit 2
  fi
}

find_favorite_db() {
  local c
  if [ -n "$WX_FAV_DB" ] && [ -f "$WX_FAV_DB" ]; then
    printf '%s' "$WX_FAV_DB"
    return 0
  fi
  for c in "$HOME"/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/*/db_storage/favorite/favorite.db; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# backup_file PATH — copies an existing file aside before a step overwrites it.
#
# The capture directory is raw material: a re-run replaces derived files
# (classified.json, favorites.json) but must not silently destroy a version the
# user cared about. Backups land in the state dir, not next to the original —
# the vault's raw/ area should not fill up with .bak files.
backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local dest="$WX_FAV_STATE_DIR/backups"
  mkdir -p "$dest" 2>/dev/null || return 0
  cp -p "$f" "$dest/$(basename "$f").$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
}

find_viz_skill() {
  local c
  if [ -n "$WX_FAV_VIZ_SKILL" ] && [ -d "$WX_FAV_VIZ_SKILL" ]; then
    printf '%s' "$WX_FAV_VIZ_SKILL"
    return 0
  fi
  for c in "$HOME/.claude/skills/wx-favorites-report" \
           "$HOME/.claude/skills/wechat-favorites-viz" \
           "$HOME/.claude/skills/wx-favorites-viz"; do
    [ -d "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

find_scraper_skill() {
  local c
  if [ -n "$WX_FAV_SCRAPER_SKILL" ] && [ -d "$WX_FAV_SCRAPER_SKILL" ]; then
    printf '%s' "$WX_FAV_SCRAPER_SKILL"
    return 0
  fi
  for c in "$HOME/.claude/skills/wechat-article-scraper"; do
    [ -d "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------------------
# export
# --------------------------------------------------------------------------

cmd_export() {
  local keylog="" key="" arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --keylog) shift; keylog="${1:-}" ;;
      --keylog=*) keylog="${1#--keylog=}" ;;
      --key) shift; key="${1:-}" ;;
      --key=*) key="${1#--key=}" ;;
      *) die "{\"ok\":false,\"error\":\"unknown_arg\",\"arg\":\"$1\"}" ;;
    esac
    shift
  done

  local dataset viz
  dataset="$(wfc_dataset_dir)"
  viz="$(find_viz_skill || true)"

  if [ -z "$viz" ] || [ ! -f "$viz/scripts/parse_favorites.py" ]; then
    die "{\"ok\":false,\"error\":\"viz_skill_missing\",\"detail\":\"需要 wx-favorites-report skill 提供 parse_favorites.py\",\"fix\":\"bash scripts/wfc_setup.sh --init\"}" 1
  fi

  local fav_db
  fav_db="$(find_favorite_db || true)"
  if [ -z "$fav_db" ]; then
    die "{\"ok\":false,\"error\":\"wechat_db_not_found\",\"detail\":\"没找到 favorite.db\",\"fix\":\"登录微信 Mac 客户端后重试，或用 WX_FAV_DB 指定路径\"}" 1
  fi

  if [ ! -x "$VENV_PY" ]; then
    die "{\"ok\":false,\"error\":\"venv_missing\",\"detail\":\"解密环境不存在：$VENV_PY\",\"fix\":\"bash scripts/wfc_setup.sh --init\"}" 1
  fi

  # 拷一份再解密。微信运行期间主库旁边有 -wal，只解主库会漏掉未 checkpoint
  # 的帧，所以两个文件一起拷，但绝不碰原库。
  local work="$WX_FAV_STATE_DIR/work"
  mkdir -p "$work" || die '{"ok":false,"error":"mkdir_failed"}'
  cp -f "$fav_db" "$work/favorite.db" || die '{"ok":false,"error":"db_copy_failed"}'
  cp -f "$fav_db-wal" "$work/favorite.db-wal" 2>/dev/null || true
  cp -f "$fav_db-shm" "$work/favorite.db-shm" 2>/dev/null || true

  # 密钥来源：显式 --key > --keylog > 上一次 frida 日志
  [ -z "$keylog" ] && [ -z "$key" ] && [ -f "$WX_FAV_STATE_DIR/wechat_frida_keys.log" ] \
    && keylog="$WX_FAV_STATE_DIR/wechat_frida_keys.log"

  if [ -z "$key" ] && [ -z "$keylog" ]; then
    die "{\"ok\":false,\"error\":\"key_required\",\"detail\":\"没有可用密钥，favorite.db 是 SQLCipher 加密的\",\"next\":\"$VENV_PY $SKILL_DIR/scripts/extract_key.py --app <已重签名的 WeChat.app> --seconds 300 --log $WX_FAV_STATE_DIR/wechat_frida_keys.log\",\"note\":\"需要先关掉正在运行的微信；操作细节见 references/decrypt-and-export.md\"}" 2
  fi

  mkdir -p "$dataset"
  backup_file "$dataset/favorite_plain.db"
  backup_file "$dataset/favorites.json"

  err "解密 $fav_db → $dataset/favorite_plain.db"
  local decrypt_args=(--input "$work/favorite.db" --output "$dataset/favorite_plain.db")
  if [ -n "$key" ]; then
    decrypt_args+=(--key "$key")
  else
    decrypt_args+=(--keylog "$keylog")
  fi
  if ! "$VENV_PY" "$SKILL_DIR/scripts/decrypt_favorite_db.py" "${decrypt_args[@]}" >&2; then
    die "{\"ok\":false,\"error\":\"decrypt_failed\",\"detail\":\"解密失败，密钥可能与当前库不匹配（微信升级后密钥会变）\"}" 1
  fi

  err "解析 → $dataset/favorites.json"
  if ! "$VENV_PY" "$viz/scripts/parse_favorites.py" \
        --input "$dataset/favorite_plain.db" \
        --output "$dataset/favorites.json" >&2; then
    die '{"ok":false,"error":"parse_failed"}' 1
  fi

  local total
  total="$("$VENV_PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('stats',{}).get('total',0))" "$dataset/favorites.json" 2>/dev/null || echo 0)"

  # WAL 里的帧没有合并进主库的话，这份快照可能不是最新的。退出微信让它
  # checkpoint 一次，或者用官方 sqlcipher CLI 读穿 WAL。
  local wal="false" note=""
  if [ -f "$work/favorite.db-wal" ]; then
    wal="true"
    note="检测到 WAL 文件：本次只解了主库，尚未 checkpoint 的帧不在其中。退出微信让主库收完 WAL，或用官方 sqlcipher CLI 的 sqlcipher_export 读穿 WAL 后重跑。"
  fi

  printf '{"ok":true,"command":"export","favorites_json":"%s","plain_db":"%s","source_db":"%s","total":%s,"wal_present":%s,"note":"%s"}\n' \
    "$(wfc_json_escape "$dataset/favorites.json")" \
    "$(wfc_json_escape "$dataset/favorite_plain.db")" \
    "$(wfc_json_escape "$fav_db")" \
    "${total:-0}" \
    "$wal" \
    "$(wfc_json_escape "$note")"
}

# --------------------------------------------------------------------------
# classify
# --------------------------------------------------------------------------

cmd_classify() {
  local tier="" limit="" md="" arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) shift; tier="${1:-}" ;;
      --tier=*) tier="${1#--tier=}" ;;
      --limit) shift; limit="${1:-}" ;;
      --limit=*) limit="${1#--limit=}" ;;
      --md) shift; md="${1:-}" ;;
      --md=*) md="${1#--md=}" ;;
      *) die "{\"ok\":false,\"error\":\"unknown_arg\",\"arg\":\"$1\"}" ;;
    esac
    shift
  done

  local dataset
  dataset="$(wfc_dataset_dir)"
  [ -f "$dataset/favorites.json" ] \
    || die "{\"ok\":false,\"error\":\"favorites_missing\",\"path\":\"$dataset/favorites.json\",\"fix\":\"先跑 wfc_capture.sh export\"}" 1

  # The URL lists hold every tier; --tier here only narrows them further.
  # Which tier to scrape is a scrape-time decision (scrape --tier).
  [ -n "$tier" ] || tier="all"
  [ -n "$limit" ] || limit="$WX_FAV_LIMIT"

  backup_file "$dataset/classified.json"

  local py="python3"
  command -v python3 >/dev/null 2>&1 || py="$VENV_PY"

  local args=(--input "$dataset/favorites.json"
              --output "$dataset/classified.json"
              --urls-dir "$dataset/urls"
              --taxonomy "$SKILL_DIR/data/taxonomy.json"
              --tier "${tier:-all}")
  [ -n "$limit" ] && [ "$limit" != "0" ] && args+=(--limit "$limit")
  [ -n "$md" ] && args+=(--md "$md")

  local out
  out="$("$py" "$SKILL_DIR/scripts/wfc_classify.py" "${args[@]}" 2>/dev/null)"
  if [ $? -ne 0 ]; then
    die '{"ok":false,"error":"classify_failed"}' 1
  fi
  printf '%s\n' "$out"
}

# --------------------------------------------------------------------------
# scrape
# --------------------------------------------------------------------------

# Runs one chunk of URLs through the article scraper.
#
# Prints two kinds of line:
#   +URL   this chunk actually fetched it
#   -URL   still missing after the chunk (it failed)
#
# The distinction matters: .index.json is the dedup source, and it also holds
# URLs scraped in an EARLIER run. If we only asked "is it in the index now?",
# every previously-scraped URL would be counted as newly fetched — the receipt
# would say 149 while 138 files existed on disk. So snapshot the index before
# the chunk and diff.
run_chunk() {
  # run_chunk CATEGORY OUT_ROOT URL...
  local category="$1" out_root="$2"; shift 2
  local urls=("$@")
  [ ${#urls[@]} -eq 0 ] && return 0

  local account="$category"
  local index="$out_root/$account/.index.json"
  local py="python3"
  command -v python3 >/dev/null 2>&1 || py="$VENV_PY"

  # 抓之前已有的 URL
  local before
  before="$("$py" - "$index" <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        for u in json.load(f):
            print(u)
except Exception:
    pass
PY
)"

  local cmd=(python3 "$SCRAPER_SKILL/scripts/scrape.py" "$account" "${#urls[@]}"
             --out "$out_root" --delay "$WX_FAV_DELAY" --tag "$WX_FAV_TAG"
             --session "$WX_FAV_SESSION")
  local u
  for u in "${urls[@]}"; do cmd+=(--url "$u"); done

  err "  · ${#urls[@]} 篇 → $out_root/$account"
  # </dev/null is load-bearing: the caller loops over a heredoc, and scrape.py
  # would otherwise read the remaining categories off our stdin.
  "${cmd[@]}" </dev/null >/dev/null 2>>"$WX_FAV_STATE_DIR/scrape.log" || true

  # 抓之后：before 里没有、after 里有的 = 这次新抓到的；after 里都没有的 = 失败
  "$py" - "$index" "$before" "${urls[@]}" <<'PY'
import json, os, sys
index_path, before_blob = sys.argv[1], sys.argv[2]
urls = sys.argv[3:]
before = set(x for x in before_blob.split("\n") if x)
after = set()
if os.path.exists(index_path):
    try:
        with open(index_path, encoding="utf-8") as f:
            after = set(json.load(f).keys())
    except Exception:
        pass
for u in urls:
    if u not in after:
        print("-" + u)
    elif u not in before:
        print("+" + u)
PY
}

cmd_scrape() {
  local category_filter="" limit="" dry_run="false" tier="" retry_failed="true" arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --category) shift; category_filter="${1:-}" ;;
      --category=*) category_filter="${1#--category=}" ;;
      --tier) shift; tier="${1:-}" ;;
      --tier=*) tier="${1#--tier=}" ;;
      --limit) shift; limit="${1:-}" ;;
      --limit=*) limit="${1#--limit=}" ;;
      --dry-run) dry_run="true" ;;
      --no-retry) retry_failed="false" ;;
      *) die "{\"ok\":false,\"error\":\"unknown_arg\",\"arg\":\"$1\"}" ;;
    esac
    shift
  done

  local dataset urls_dir articles
  dataset="$(wfc_dataset_dir)"
  urls_dir="$dataset/urls"
  articles="$dataset/articles"

  [ -d "$urls_dir" ] \
    || die "{\"ok\":false,\"error\":\"urls_missing\",\"path\":\"$urls_dir\",\"fix\":\"先跑 wfc_capture.sh classify\"}" 1

  SCRAPER_SKILL="$(find_scraper_skill || true)"
  if [ -z "$SCRAPER_SKILL" ] || [ ! -f "$SCRAPER_SKILL/scripts/scrape.py" ]; then
    die '{"ok":false,"error":"scraper_skill_missing","detail":"缺少 wechat-article-scraper skill","fix":"装到 ~/.claude/skills/wechat-article-scraper，或用 WX_FAV_SCRAPER_SKILL 指定路径"}' 1
  fi

  if ! command -v "$OPENCLI_BIN" >/dev/null 2>&1; then
    die '{"ok":false,"error":"opencli_missing","detail":"抓正文需要 opencli 浏览器桥","fix":"安装 opencli 后运行 opencli doctor"}' 1
  fi

  # 抓之前先把浏览器桥修好：daemon 停着、没选 profile、上一轮留下的死标签页
  # 租约——这三样都会表现为「浏览器打开失败」，而且都不需要人来判断。
  # 这一步就是过去每次要靠 agent 逐条排查的部分，现在收进脚本里。
  local preflight
  preflight="$(bash "$SKILL_DIR/scripts/wfc_preflight.sh" --session "$WX_FAV_SESSION" --opencli "$OPENCLI_BIN" 2>/dev/null)"
  local pf_ok="false"
  printf '%s' "$preflight" | grep -q '"ok":true' && pf_ok="true"
  if [ "$pf_ok" != "true" ]; then
    die "{\"ok\":false,\"error\":\"browser_not_ready\",\"preflight\":$(printf '%s' "$preflight" | sed 's/^/"/; s/$/"/; s/"/\\"/g')}" 1
  fi

  [ -n "$limit" ] || limit="$WX_FAV_LIMIT"
  [ -n "$tier" ] || tier="$WX_FAV_TIER"

  local manifest="$urls_dir/_manifest.json"
  local index_path="$urls_dir/_index.json"
  local skipped_path="$urls_dir/_skipped.json"
  [ -f "$manifest" ] || die "{\"ok\":false,\"error\":\"manifest_missing\",\"path\":\"$manifest\"}" 1

  local py="python3"
  command -v python3 >/dev/null 2>&1 || py="$VENV_PY"

  # manifest → "category<TAB>file" 一行一个
  local pairs
  pairs="$("$py" - "$manifest" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for cat, info in m.get("categories", {}).items():
    print(f"{cat}\t{info['file']}")
PY
)"

  local total_ok=0 total_fail=0 planned=0 total_retried=0
  local failures="" fsep=""

  local cat file
  while IFS="$(printf '\t')" read -r cat file; do
    [ -n "$cat" ] || continue
    if [ -n "$category_filter" ] && [ "$cat" != "$category_filter" ]; then continue; fi
    local urlfile="$urls_dir/$file"
    [ -f "$urlfile" ] || continue

    local urls=()
    while IFS= read -r u; do
      [ -n "$u" ] && urls+=("$u")
    done < "$urlfile"

    local failed_urls=()

    # 层级按条目过滤，不是按清单文件过滤。urls/_index.json 记录了每个 URL
    # 属于哪一层，所以 scrape --tier T2 拿到的就是 T2 那批条目本身。
    if [ -n "$tier" ] && [ "$tier" != "all" ] && [ -f "$index_path" ] && [ ${#urls[@]} -gt 0 ]; then
      # 注意：不能写成 urls=("$(... "${urls[@]}" ...)")。带引号的 "$(...)" 在
      # 数组赋值里是**一个**词——多行输出会被塞进单个元素，于是 urls 只剩 1 个
      # 元素、内容是一整块换行文本。先落到临时文件，再按行读回数组。
      local tier_file
      tier_file="$(mktemp -t wfc-tier-XXXXXX)"
      "$py" - "$index_path" "$tier" "${urls[@]}" > "$tier_file" <<'PY'
import json, sys
index = json.load(open(sys.argv[1], encoding="utf-8"))
tier = sys.argv[2]
for u in sys.argv[3:]:
    if index.get(u, {}).get("tier") == tier:
        print(u)
PY
      local kept=()
      while IFS= read -r u; do
        [ -n "$u" ] && kept+=("$u")
      done < "$tier_file"
      rm -f "$tier_file"
      urls=(${kept[@]+"${kept[@]}"})
    fi

    # --limit 是**总量**预算，不是每个类目各取这么多。用户说「抓 30 篇」就该拿到
    # 30 篇，而不是 14 个类目各 30 篇（那是 420 篇，是脚枪）。
    # 类目按分类结果的顺序处理（大的类目在前），预算先到先得。
    if [ -n "$limit" ] && [ "$limit" != "0" ]; then
      local remaining=$((limit - planned))
      if [ "$remaining" -le 0 ]; then
        err "== $cat （预算已用完，跳过）=="
        continue
      fi
      if [ ${#urls[@]} -gt "$remaining" ]; then
        urls=("${urls[@]:0:$remaining}")
      fi
    fi

    planned=$((planned + ${#urls[@]}))
    err "== $cat （${#urls[@]} 篇）=="

    if [ "$dry_run" = "true" ]; then
      err "  （dry-run，不抓）"
      continue
    fi

    # 分块：浏览器会话连抓十几篇后会整体僵死，≤6 篇一块最稳
    #
    # run_chunk 的输出有两种行：`+URL` 是这一块真的抓到了，`-URL` 是仍然没有。
    # 「上一轮就抓过的」既不是 + 也不是 - —— 它压根没被抓，不该进任何计数。
    local i=0 chunk=() n=0
    while [ $i -lt ${#urls[@]} ]; do
      chunk+=("${urls[$i]}")
      i=$((i + 1)); n=$((n + 1))
      if [ "$n" -ge "$WX_FAV_CHUNK" ] || [ "$i" -ge ${#urls[@]} ]; then
        local cres
        cres="$(run_chunk "$cat" "$articles" "${chunk[@]}")"
        local m
        while IFS= read -r m; do
          [ -z "$m" ] && continue
          case "$m" in
            +*) total_ok=$((total_ok + 1)) ;;
            -*) failed_urls+=("${m#-}") ;;
          esac
        done <<EOF
$cres
EOF
        chunk=(); n=0
      fi
    done

    # 只重试这一类失败的那些篇，不整批重来。
    #
    # 为什么要重试：opencli 的浏览器会话跑到十几篇后会整体僵死，症状是这一块
    # 剩下的篇全失败。下一块是新会话，往往又好了——所以失败的是「这一块」，
    # 不是「这些文章」。重抓已经成功的那些会撞上重名逻辑，所以只重试缺的。
    #
    # 为什么要限量：原文被删除 / 违规下架 / 作者隐私设置的条目，重试一万次也一样。
    # 每篇只重试一次，还不行就如实报成失效。
    local final_failed=()
    if [ ${#failed_urls[@]} -gt 0 ] && [ "$retry_failed" = "true" ]; then
      err "== $cat （重试 ${#failed_urls[@]} 篇）=="
      local rretry=() rn=0 ri=0
      while [ $ri -lt ${#failed_urls[@]} ]; do
        rretry+=("${failed_urls[$ri]}")
        ri=$((ri + 1)); rn=$((rn + 1))
        if [ "$rn" -ge "$WX_FAV_CHUNK" ] || [ "$ri" -ge ${#failed_urls[@]} ]; then
          local rres rm
          rres="$(run_chunk "$cat" "$articles" "${rretry[@]}")"
          while IFS= read -r rm; do
            [ -z "$rm" ] && continue
            case "$rm" in
              +*) total_ok=$((total_ok + 1)) ;;
              -*) final_failed+=("${rm#-}") ;;
            esac
          done <<EOF
$rres
EOF
          total_retried=$((total_retried + rn))
          rretry=(); rn=0
        fi
      done
    else
      # 不重试：第一次没抓到的就是最终失败的那些
      final_failed=(${failed_urls[@]+"${failed_urls[@]}"})
    fi

    # 失败只在重试之后统计一次。重试成功的那些不该还在失败清单里，
    # 重试仍失败的也不该被数两遍。
    local fm
    for fm in ${final_failed[@]+"${final_failed[@]}"}; do
      [ -z "$fm" ] && continue
      failures="${failures}${fsep}{\"category\":\"$(wfc_json_escape "$cat")\",\"url\":\"$(wfc_json_escape "$fm")\"}"
      fsep=","
      total_fail=$((total_fail + 1))
    done
  done <<EOF
$pairs
EOF

  # 失败条目落盘：urls/_failed.json 跨轮次累积，已经落地的自动移除。
  #
  # 为什么要有这个文件：「哪些是真抓不到」和「哪些只是还没抓」必须能分开。
  # 没有它，缺口台账会把 200 条没抓过的旧技术文章和 5 条原文已删除的
  # 混成一坨「抓不到的」，读的人会以为全都试过了。
  if [ "$dry_run" != "true" ]; then
    "$py" - "$urls_dir/_failed.json" "$index_path" "$failures" <<'PY'
import json, os, sys, glob
failed_path, index_path, blob = sys.argv[1], sys.argv[2], sys.argv[3]

data = {}
if os.path.exists(failed_path):
    try:
        with open(failed_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

try:
    items = json.loads("[" + blob + "]") if blob.strip() else []
except Exception:
    items = []

meta = {}
try:
    with open(index_path, encoding="utf-8") as f:
        meta = json.load(f)
except Exception:
    meta = {}

for it in items:
    u = it.get("url", "")
    if not u:
        continue
    m = meta.get(u, {})
    data[u] = {
        "category": it.get("category", "") or m.get("category", ""),
        "tier": m.get("tier", ""),
        "title": m.get("title", ""),
        "timestamp": m.get("timestamp", ""),
    }

# 已经落地的（某次重试成功了）从失败清单里去掉
landed = set()
for p in glob.glob(os.path.join(os.path.dirname(os.path.dirname(failed_path)),
                                "articles", "*", ".index.json")):
    try:
        with open(p, encoding="utf-8") as f:
            landed.update(json.load(f).keys())
    except Exception:
        pass
for u in list(data):
    if u in landed:
        del data[u]

with open(failed_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
PY
  fi

  if [ "$dry_run" = "true" ]; then
    printf '{"ok":true,"command":"scrape","dry_run":true,"planned":%s,"articles_dir":"%s"}\n' \
      "$planned" "$(wfc_json_escape "$articles")"
    return 0
  fi

  # 不是微信文章链接的收藏（抖音视频页、头条、51CTO …）不进待抓清单——
  # 抓取器只处理 mp.weixin.qq.com，让它们进去只会空转三次重试。数量报出来，
  # 不是失败，是本来就抓不了。
  local skipped_n=0
  if [ -f "$skipped_path" ]; then
    skipped_n="$("$py" -c "import json,sys;print(len(json.load(open(sys.argv[1],encoding='utf-8'))))" "$skipped_path" 2>/dev/null || echo 0)"
  fi

  printf '{"ok":%s,"command":"scrape","articles_dir":"%s","fetched":%s,"failed":%s,"retried":%s,"skipped_not_wechat":%s,"failed_items":[%s],"preflight":"%s","note":"失败的条目多半是原文已删除 / 违规下架 / 隐私限制，每篇只重试一次，还不行就是真的失效"}\n' \
    "$([ "$total_fail" -eq 0 ] && echo true || echo false)" \
    "$(wfc_json_escape "$articles")" \
    "$total_ok" "$total_fail" "$total_retried" "$skipped_n" "$failures" \
    "$(wfc_json_escape "$preflight")"
}

# --------------------------------------------------------------------------
# capture — the whole fixed flow behind one command
# --------------------------------------------------------------------------

# The point of this subcommand is token cost. Every step is a script that
# prints one JSON line; the agent reads one receipt at the end instead of
# driving four scripts, diagnosing the browser, and reading logs.
cmd_capture() {
  local tier="" limit="" category="" dry_run="false" skip_report="false" arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) shift; tier="${1:-}" ;;
      --tier=*) tier="${1#--tier=}" ;;
      --limit) shift; limit="${1:-}" ;;
      --limit=*) limit="${1#--limit=}" ;;
      --category) shift; category="${1:-}" ;;
      --category=*) category="${1#--category=}" ;;
      --dry-run) dry_run="true" ;;
      --no-report) skip_report="true" ;;
      *) die "{\"ok\":false,\"error\":\"unknown_arg\",\"arg\":\"$1\"}" ;;
    esac
    shift
  done

  local dataset out rc
  dataset="$(wfc_dataset_dir)"

  # export 只在还没有 favorites.json 时才跑 —— 它是最贵的一步（要密钥、要用户
  # 退出微信）。已经导出过就直接用。
  if [ -f "$dataset/favorites.json" ]; then
    err "capture: 已有 favorites.json，跳过 export"
  else
    out="$(cmd_export)"; rc=$?
    if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
    err "capture: export 完成"
  fi

  out="$(cmd_classify)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
  err "capture: classify 完成"

  local scrape_args=()
  [ -n "$tier" ] && scrape_args+=(--tier "$tier")
  [ -n "$limit" ] && scrape_args+=(--limit "$limit")
  [ -n "$category" ] && scrape_args+=(--category "$category")
  [ "$dry_run" = "true" ] && scrape_args+=(--dry-run)

  local scrape_receipt
  scrape_receipt="$(cmd_scrape "${scrape_args[@]}")"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$scrape_receipt"; exit "$rc"; fi
  err "capture: scrape 完成"

  if [ "$skip_report" != "true" ]; then
    out="$(cmd_report)"; rc=$?
    if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
  fi

  # One compact receipt. Everything the caller needs, nothing it has to parse.
  "$VENV_PY" - "$dataset" "$scrape_receipt" <<'PY'
import json, os, sys
dataset, scrape_receipt = sys.argv[1], sys.argv[2]
try:
    scr = json.loads(scrape_receipt)
except Exception:
    scr = {"raw": scrape_receipt}

def load(name):
    try:
        with open(os.path.join(dataset, name), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

cls = load("classified.json")
print(json.dumps({
    "ok": bool(scr.get("ok", True)),
    "command": "capture",
    "dataset_dir": dataset,
    "favorites": cls.get("total"),
    "by_l1": cls.get("by_l1", {}),
    "by_tier": cls.get("by_tier", {}),
    "categories": len(cls.get("by_category", {})),
    "planned": scr.get("planned"),
    "fetched": scr.get("fetched"),
    "failed": scr.get("failed"),
    "failed_items": scr.get("failed_items", []),
    "articles_dir": scr.get("articles_dir"),
    "report_html": os.path.join(dataset, "report.html"),
    "preflight": scr.get("preflight"),
}, ensure_ascii=False))
PY
}

# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------

cmd_report() {
  local dataset viz
  dataset="$(wfc_dataset_dir)"
  viz="$(find_viz_skill || true)"

  if [ -z "$viz" ] || [ ! -f "$viz/scripts/generate_report.py" ]; then
    die '{"ok":false,"error":"viz_skill_missing","detail":"缺少 wx-favorites-report 的 generate_report.py","fix":"bash scripts/wfc_setup.sh --init"}' 1
  fi
  [ -f "$dataset/favorites.json" ] \
    || die "{\"ok\":false,\"error\":\"favorites_missing\",\"fix\":\"先跑 wfc_capture.sh export\"}" 1

  local py="python3"
  command -v python3 >/dev/null 2>&1 || py="$VENV_PY"
  "$py" "$viz/scripts/generate_report.py" \
    --input "$dataset/favorites.json" \
    --output "$dataset/report.html" >&2 \
    || die '{"ok":false,"error":"report_failed"}' 1

  printf '{"ok":true,"command":"report","report_html":"%s"}\n' \
    "$(wfc_json_escape "$dataset/report.html")"
}

# --------------------------------------------------------------------------
# all
# --------------------------------------------------------------------------

cmd_all() {
  # Each step runs in a subshell so its stdout stays a single JSON line. The
  # sub-step's exit code is preserved — a missing key (2) and a failed decrypt
  # (1) mean different things to whoever is driving this.
  #
  # The final receipt summarises all four steps rather than repeating only the
  # last one: "all" that reports just the report step tells the caller nothing
  # about whether 40 articles actually landed.
  local out rc exp cls scr rep
  out="$(cmd_export)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
  exp="$out"; err "export: $exp"

  out="$(cmd_classify)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
  cls="$out"; err "classify: $cls"

  out="$(cmd_scrape "$@")"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
  scr="$out"; err "scrape: $scr"

  out="$(cmd_report)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; exit "$rc"; fi
  rep="$out"

  # Pull the numbers out of each step's receipt so the summary is one object
  # instead of four nested ones.
  local py="python3"
  command -v python3 >/dev/null 2>&1 || py="$VENV_PY"
  "$py" - "$exp" "$cls" "$scr" "$rep" <<'PY'
import json, sys
exp, cls, scr, rep = (json.loads(a) for a in sys.argv[1:5])
summary = {
    "ok": True,
    "command": "all",
    "export": {"total": exp.get("total"), "wal_present": exp.get("wal_present"),
               "favorites_json": exp.get("favorites_json")},
    "classify": {"total": cls.get("total"), "by_l1": cls.get("by_l1"),
                 "by_tier": cls.get("by_tier"),
                 "categories": len(cls.get("url_files", {}))},
    "scrape": {"planned": scr.get("planned"), "fetched": scr.get("fetched"),
               "failed": scr.get("failed"), "articles_dir": scr.get("articles_dir"),
               "failed_items": scr.get("failed_items", [])},
    "report": {"report_html": rep.get("report_html")},
}
print(json.dumps(summary, ensure_ascii=False))
PY
}

# --------------------------------------------------------------------------
# entry
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
wfc_capture.sh — 把微信收藏抓进 Obsidian

用法：
  bash scripts/wfc_capture.sh doctor                  依赖体检（JSON）
  bash scripts/wfc_capture.sh config-info [--json]    看解析出的配置
  bash scripts/wfc_capture.sh export [--keylog P | --key HEX]
  bash scripts/wfc_capture.sh classify [--tier T1|T2|T3|all] [--limit N]
  bash scripts/wfc_capture.sh scrape [--category C] [--tier T] [--limit N] [--dry-run]
  bash scripts/wfc_capture.sh report
  bash scripts/wfc_capture.sh all [scrape 的参数...]
  bash scripts/wfc_capture.sh capture [--tier T] [--limit N] [--category C] [--dry-run]
                                      # 整条流程一条命令；已导出过就跳过 export

退出码：0 成功 / 1 步骤失败 / 2 配置缺失
EOF
}

case "${1:-}" in
  doctor)
    shift
    exec bash "$SKILL_DIR/scripts/wfc_doctor.sh" "$@"
    ;;
  config-info|--config-info)
    shift
    need_config
    wfc_config_info "${1:-text}"
    ;;
  export)
    shift
    need_config
    cmd_export "$@"
    ;;
  classify)
    shift
    need_config
    cmd_classify "$@"
    ;;
  scrape)
    shift
    need_config
    cmd_scrape "$@"
    ;;
  capture)
    shift
    need_config
    cmd_capture "$@"
    ;;
  report)
    shift
    need_config
    cmd_report "$@"
    ;;
  all)
    shift
    need_config
    cmd_all "$@"
    ;;
  --help|-h|"")
    usage
    [ -z "${1:-}" ] && exit 2
    exit 0
    ;;
  *)
    usage
    die "{\"ok\":false,\"error\":\"unknown_command\",\"command\":\"$1\"}"
    ;;
esac
