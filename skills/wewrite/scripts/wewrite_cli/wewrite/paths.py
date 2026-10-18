"""WeWrite 路径解析 —— 用户状态与代码/skill 仓库解耦的唯一枢纽。

两个根，各管各的：

| 根 | 环境变量 | 默认 | 装什么 |
|----|----------|------|--------|
| 状态根 | `WEWRITE_HOME` | `~/.wewrite` | 凭证 config.yaml、style.yaml、history.yaml、playbook.md、corpus/、exemplars/、lessons/、themes/、personas/、current_run |
| 产出根 | `WEWRITE_OUT_DIR` | `$WEWRITE_HOME/output` | **每次写作任务的全部产物**：runs/<run_id>/{article.md, draft.md, brief.yaml, …} |

产出根默认落在状态根里，这样一个未配置的安装行为不变。把 `WEWRITE_OUT_DIR`
指到 Obsidian Vault（`$VAULT_DIR/output/WeWrite`）之后，成稿、配图、预览和
审稿报告一起进 vault，而凭证和学习状态仍然留在机器本地 —— 这一点是硬边界：
**config.yaml 永远不会出现在产出根下**，否则 API key 会被 iCloud 同步进一个
git 仓库。

v2.x 之前状态散在 skill 仓库根，`wewrite migrate` 负责一次性迁移。
"""

import os
from pathlib import Path

# 状态根下的子目录（ensure_home 时创建）
_SUBDIRS = ["exemplars", "corpus", "lessons", "themes", "personas"]


def home() -> Path:
    """状态根：$WEWRITE_HOME 或 ~/.wewrite。不保证存在（写操作前用 ensure_home）。"""
    return Path(os.environ.get("WEWRITE_HOME", "") or (Path.home() / ".wewrite"))


def out_dir() -> Path:
    """产出根：$WEWRITE_OUT_DIR，或状态根下的 output/。

    runs.py 把所有 artifacts 路径按本根做相对化，所以这里改一次，
    整条写作管线的落盘位置就整体搬家。
    """
    override = os.environ.get("WEWRITE_OUT_DIR", "").strip()
    return Path(override) if override else home() / "output"


def ensure_home() -> Path:
    """创建状态根、产出根及标准子目录（幂等），返回状态根。"""
    h = home()
    h.mkdir(parents=True, exist_ok=True)
    for sub in _SUBDIRS:
        (h / sub).mkdir(exist_ok=True)
    out = out_dir()
    out.mkdir(parents=True, exist_ok=True)
    (out / "runs").mkdir(exist_ok=True)
    return h


def config_path() -> Path:
    return home() / "config.yaml"


def style_path() -> Path:
    return home() / "style.yaml"


def history_path() -> Path:
    return home() / "history.yaml"


def playbook_path() -> Path:
    return home() / "playbook.md"


def runs_dir() -> Path:
    """每次写作任务的工作目录。落在产出根下，因此默认就在 vault 里。"""
    return out_dir() / "runs"


def current_run_path() -> Path:
    return home() / "current_run"


def exemplars_dir() -> Path:
    return home() / "exemplars"


def corpus_dir() -> Path:
    return home() / "corpus"


def lessons_dir() -> Path:
    return home() / "lessons"


def user_themes_dir() -> Path:
    """learn-theme 学到的用户主题；load_theme 在包内置主题之前先查这里。"""
    return home() / "themes"
