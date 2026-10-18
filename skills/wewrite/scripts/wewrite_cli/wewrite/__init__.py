"""WeWrite runtime — 公众号内容管道的确定性工具层（CLI: `wewrite`）。

本副本由 mario-skills 移植而来，相对上游 wewrite 做了两处改造：

1. **产出与状态分根**（`paths.py`）—— `WEWRITE_OUT_DIR` 独立于 `WEWRITE_HOME`，
   于是全部写作产物可以落进 Obsidian Vault，而凭证和学习状态留在机器本地。
2. **配置走 mario-skills 共享 `.env`**（`envconf.py`）—— 不再各自维护
   config.yaml，改为读 `.mario-skills/.env`，四级查找链 + `--config-info` 溯源。
"""

# 版本单一真源 = 本 skill 目录下的 VERSION 文件；打包安装时回退到包 metadata
def _resolve_version() -> str:
    try:
        from pathlib import Path
        # scripts/wewrite_cli/wewrite/__init__.py → 上溯三层到 skill 根
        source_version = Path(__file__).resolve().parents[3] / "VERSION"
        if source_version.exists():
            return source_version.read_text().strip()
    except Exception:
        pass
    try:
        from importlib.metadata import version
        return version("wewrite")
    except Exception:
        pass
    return "0.0.0+unknown"


__version__ = _resolve_version()
