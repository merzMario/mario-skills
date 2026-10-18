#!/usr/bin/env bash
# wewrite 的唯一入口。解析 .mario-skills/.env → 设环境变量 → 调 Python CLI。
#
# 为什么要这一层而不是直接 `wewrite`：本脚本同时承担三件 CLI 不该管的事
# —— 交互式初始化（--init/--detect，只给人跑）、配置溯源（--config-info）、
# 以及把 Python 解释器和 skill 目录的位置固定下来，不依赖调用方的 CWD。
#
# ⚠️ --init 和 --detect 不要在 LLM 调用里跑。配置归人管。

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_ROOT="$SKILL_DIR/scripts/wewrite_cli"

# 依赖探测：需要一个装齐了 yaml / requests / markdown / bs4 / cssutils /
# pygments / PIL 的解释器。系统 python3 常常没有 yaml（macOS 自带的就没有），
# 所以这里按「谁真的能 import」挑，而不是按路径猜。
#
# 顺序：显式指定 → 本 skill 的 .venv → 上游 uv tool 的解释器 → PATH 上的 python3。
probe_python() {
  local candidate
  for candidate in "$@"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    if "$candidate" -c 'import yaml, requests, markdown, bs4, cssutils, pygments, PIL' \
        >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

PYTHON_BIN="${WEWRITE_PYTHON:-}"
if [ -z "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(probe_python \
    "$SKILL_DIR/.venv/bin/python" \
    "$HOME/.local/share/uv/tools/wewrite/bin/python" \
    "$(command -v python3 || true)")" || {
      printf '{"ok":false,"error":"python_deps_missing",' >&2
      printf '"need":["pyyaml","requests","markdown","beautifulsoup4","cssutils","Pygments","Pillow"],' >&2
      printf '"hint":"人跑 `bash scripts/wewrite.sh --setup` 建独立虚拟环境；' >&2
      printf '或用 WEWRITE_PYTHON=<解释器> 指定一个已装齐依赖的解释器"}\n' >&2
      exit 3
    }
fi

# --- .env 查找 ---------------------------------------------------------------
# 沿用 mario-skills 四级链：process env → <cwd>/.mario-skills/.env
#                        → ~/.mario-skills/.env → 内置默认
# 只解析，绝不 source —— 见下方 env_get 的说明。
MARIO_SKILLS_ENV="${MARIO_SKILLS_ENV:-$HOME/.mario-skills/.env}"
MARIO_SKILLS_PROJECT_ENV="${MARIO_SKILLS_PROJECT_ENV:-$PWD/.mario-skills/.env}"

# 读一个 dotenv 文件里的某个键。最后一次定义生效。
#
# 为什么逐行解析而不是 `source`：这个文件里存的是公众号 appsecret 和图片 API key。
# source 等于把这个文件交给 bash 当代码执行 —— 里面一个 `$(curl …)` 或者 `;`
# 就成了执行入口。解析则只把它当字面量文本。值里出现 `=` 也没问题，
# 因为只按第一个 `=` 切分。
env_get() {
  local want="$1" file="$2"
  local line key val found=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # 去掉行首空白（bash 3.2 没有 ${var,,} 可用）
    while :; do
      case "$line" in
        [[:space:]]*) line="${line#?}" ;;
        *) break ;;
      esac
    done
    case "$line" in ''|'#'*) continue ;; esac
    [ "${line#*=}" = "$line" ] && continue
    key="${line%%=*}"
    val="${line#*=}"
    while :; do
      case "$key" in [[:space:]]*) key="${key#?}" ;; *) break ;; esac
    done
    while :; do
      case "$val" in [[:space:]]*) val="${val#?}" ;; *) break ;; esac
    done
    while :; do
      case "$val" in *[[:space:]]) val="${val%?}" ;; *) break ;; esac
    done
    case "$key" in
      export\ *) key="${key#export }" ;;
    esac
    # 剥一层配对引号，用途是保住首尾空格
    case "$val" in
      \"*\") val="${val:1:${#val}-2}" ;;
      \'*\') val="${val:1:${#val}-2}" ;;
    esac
    [ "$key" = "$want" ] && found="$val"
  done < "$file"
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# 逐键取值：process env 优先，然后项目级，再用户级。
# 用 printf -v 而不是 eval —— 见上面关于 source 的说明。
# $1=键名  $2=输出变量名（调用方给，避免 ${!key} 间接引用把自己绕进去）
lookup() {
  local key="$1" outvar="$2" val=""
  local from_env="${!key:-}"
  if [ -n "$from_env" ]; then
    printf -v "$outvar" '%s' "$from_env"
    return 0
  fi
  if val="$(env_get "$key" "$MARIO_SKILLS_PROJECT_ENV")"; then :; fi
  if [ -z "$val" ]; then
    if val="$(env_get "$key" "$MARIO_SKILLS_ENV")"; then :; fi
  fi
  printf -v "$outvar" '%s' "$val"
}

# 这些查找只给 --init 写默认值用；实际运行时的解析全部在 Python 侧完成
# （见下面 run_cli 的注释）。
#
# 累加器一律用 `*_VALUE` 后缀，不复用键名本身。复用会让
# `VAULT_DIR=""` 这行初始化**抹掉调用方传进来的真实环境变量**，而且
# `printf -v VAULT_DIR` 会连带改掉子进程继承到的值 —— 那是给溯源制造假象。
VAULT_DIR_VALUE=""
WEWRITE_HOME_VALUE=""
WEWRITE_OUT_SUBDIR_VALUE=""
WEWRITE_THEME_VALUE=""

lookup VAULT_DIR VAULT_DIR_VALUE
lookup WEWRITE_HOME WEWRITE_HOME_VALUE
lookup WEWRITE_OUT_SUBDIR WEWRITE_OUT_SUBDIR_VALUE
lookup WEWRITE_THEME WEWRITE_THEME_VALUE

usage() {
  cat <<'EOF'
wewrite —— 公众号写作管道（mario-skills 版）

用法：
  wewrite.sh <wewrite 子命令> [参数…]     正常调用，转发给 Python CLI
  wewrite.sh --config-info [--json]      打印每个配置项的值、来源和搜索路径
  wewrite.sh --detect                    本机自检（人跑）
  wewrite.sh --init [--dry-run]          写 ~/.mario-skills/.env（人跑）
  wewrite.sh --setup                     建 .venv 并装依赖（人跑）
  wewrite.sh --paths                     只打印状态目录和产出目录

所有脚本都在本 SKILL.md 所在目录的 scripts/ 下，从 SKILL.md 的位置解析，
不要依赖调用时的 CWD。

配置写在 mario-skills 共享的 .mario-skills/.env（键见 examples/env.shared.example）。
EOF
}

# --- --setup -----------------------------------------------------------------
# 建一个 skill 目录内的独立虚拟环境并装依赖。
# 走 pip install，不用 `curl | bash` —— mario-skills 的硬规矩。
setup_venv() {
  local venv="$SKILL_DIR/.venv"
  printf '在 %s 建虚拟环境…\n' "$venv" >&2
  python3 -m venv "$venv"
  "$venv/bin/python" -m pip install --upgrade pip >/dev/null
  "$venv/bin/python" -m pip install \
    'markdown>=3.10' 'beautifulsoup4>=4.14' 'cssutils>=2.11' \
    'requests>=2.32' 'pyyaml>=6.0' 'Pygments>=2.17' 'Pillow>=10.0'
  printf '{"ok":true,"action":"setup","path":"%s"}\n' "$venv/bin/python"
}

# --- --init ------------------------------------------------------------------
# 逐键合并写入，兄弟技能的键原样保留 —— 一个文件服务所有技能，不能整份覆盖。
# 先写备份再改。
init_env() {
  local target="$MARIO_SKILLS_ENV"
  local dry_run="${1:-}"

  local detected_vault="$VAULT_DIR_VALUE"
  if [ -z "$detected_vault" ] && [ -f "$PWD/.obsidian/app.json" ]; then
    detected_vault="$PWD"
  fi
  if [ -z "$detected_vault" ] && [ -d "$PWD/journals" ] && [ -d "$PWD/raw" ]; then
    detected_vault="$PWD"
  fi
  local detected_home="$WEWRITE_HOME_VALUE"
  if [ -z "$detected_home" ]; then
    detected_home="$HOME/.wewrite"
  fi

  if [ -z "$detected_vault" ]; then
    printf '{"ok":false,"error":"vault_not_detected",'
    printf '"searched":["%s", "%s", "当前目录下 .obsidian/", "当前目录下 raw/ + journals/"],' \
      "$MARIO_SKILLS_PROJECT_ENV" "$MARIO_SKILLS_ENV"
    printf '"hint":"手写 VAULT_DIR=<你的 vault 绝对路径> 再跑一次 --init"}\n'
    return 2
  fi

  if [ "$dry_run" = "--dry-run" ]; then
    printf '将写入 %s（--dry-run，未落盘）:\n\n' "$target"
    printf 'VAULT_DIR=%s\n' "$detected_vault"
    printf 'WEWRITE_HOME=%s\n' "$detected_home"
    printf 'WEWRITE_OUT_SUBDIR=%s\n' "${WEWRITE_OUT_SUBDIR_VALUE:-output/WeWrite}"
    printf '\n公众号凭证、图片 provider、写作模型请自行补上，见 examples/env.shared.example。\n'
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    cp -p "$target" "$target.bak.$(date +%Y%m%d%H%M%S)"
    printf '已备份原文件到 %s.bak.*\n' "$target" >&2
  fi

  merge_key() {
    local key="$1" val="$2"
    if env_get "$key" "$target" >/dev/null 2>&1; then
      # 已存在就保留原值：--init 不该覆盖人已经配好的东西
      return 0
    fi
    printf '\n# --- wewrite（由 --init 写入 %s） ---\n%s=%s\n' \
      "$(date +%Y-%m-%d)" "$key" "$val" >> "$target"
  }

  merge_key VAULT_DIR "$detected_vault"
  merge_key WEWRITE_HOME "$detected_home"
  merge_key WEWRITE_OUT_SUBDIR "${WEWRITE_OUT_SUBDIR_VALUE:-output/WeWrite}"
  merge_key WEWRITE_THEME "${WEWRITE_THEME_VALUE:-professional-clean}"

  printf '{"ok":true,"action":"init","path":"%s"}\n' "$target"
  printf '\n已写入 %s\n' "$target" >&2
  printf '公众号凭证仍是空的：把 WECHAT_APPID / WECHAT_SECRET 补进去才能推草稿箱。\n' >&2
}

# 用 Python 跑 CLI。
#
# 刻意**不**在这里注入解析结果。这个脚本和 Python 都读同一份
# `.mario-skills/.env`，如果 bash 先把 `WEWRITE_OUT_SUBDIR`、`VAULT_DIR` 之类
# 导出成环境变量，Python 就会把它们当成 process.env —— `--config-info` 于是
# 谎报来源层。溯源是这个脚本存在的意义，不能自己先把它污染掉。
#
# 解析的唯一真源是 envconf.py；这里只负责补 PYTHONPATH。
run_cli() {
  PYTHONPATH="$CLI_ROOT${PYTHONPATH:+:$PYTHONPATH}" "$PYTHON_BIN" -m wewrite "$@"
}

# --- 入口 --------------------------------------------------------------------
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --init)
    init_env "${2:-}"
    exit $?
    ;;
  --detect)
    run_cli diagnose
    exit $?
    ;;
  --setup)
    setup_venv
    exit $?
    ;;
  --config-info)
    if [ "${2:-}" = "--json" ]; then
      run_cli config-info --json
    else
      run_cli config-info
    fi
    exit $?
    ;;
  --paths)
    run_cli home
    printf '\n'
    run_cli out-dir
    exit $?
    ;;
  '')
    usage
    exit 0
    ;;
esac

# 注意是 `run_cli "$@"` 而不是 `exec run_cli` —— run_cli 是 shell 函数，
# exec 只认外部命令。这里让 Python 进程的退出码原样透传给调用方。
run_cli "$@"
