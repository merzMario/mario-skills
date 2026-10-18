"""
Unified configuration loader for WeWrite.

Four layers, highest first. mario-skills 移植后新增了前两层，上游的两层退为兜底：

    1. process env                WECHAT_APPID=… wewrite preview
    2. <cwd>/.mario-skills/.env    mario-skills 共享配置（本技能拥有的键）
    3. ~/.mario-skills/.env       同上，用户级
    4. $WEWRITE_HOME/config.yaml  上游原生配置，作为兜底保留
    5. ~/.config/wewrite/config.yaml   上游历史兼容位置

Environment variable mapping:
    WECHAT_APPID          → wechat.appid
    WECHAT_SECRET         → wechat.secret
    WECHAT_AUTHOR         → wechat.author
    WEWRITE_IMAGE_PROVIDER → image.provider
    WEWRITE_IMAGE_API_KEY  → image.api_key
    WEWRITE_IMAGE_MODEL    → image.model
    WEWRITE_THEME          → theme

Why the .env layers sit above config.yaml: mario-skills 的规矩是全市场只有一个
配置文件。用户不该为了换个公众号 appid 去编辑 YAML。
"""

import os
from pathlib import Path

import yaml

from ..envconf import apply_to_environment
from ..paths import config_path

CONFIG_SEARCH_ORDER = [
    config_path(),                                        # $WEWRITE_HOME/config.yaml（主位置）
    Path.home() / ".config" / "wewrite" / "config.yaml",  # 历史兼容位置
]

_ENV_OVERRIDES = {
    ("wechat", "appid"): "WECHAT_APPID",
    ("wechat", "secret"): "WECHAT_SECRET",
    ("wechat", "author"): "WECHAT_AUTHOR",
    ("image", "provider"): "WEWRITE_IMAGE_PROVIDER",
    ("image", "api_key"): "WEWRITE_IMAGE_API_KEY",
    ("image", "model"): "WEWRITE_IMAGE_MODEL",
    ("theme",): "WEWRITE_THEME",
}

_cached_config: dict | None = None
_cached_path: Path | None = None


def load_config(force_reload: bool = False) -> dict:
    """Load config with caching. Environment variables override file values."""
    global _cached_config, _cached_path

    if _cached_config is not None and not force_reload:
        return _cached_config

    # .mario-skills/.env 只做一件事：把共享键搬进 os.environ。setdefault 保证
    # 真正的 process env 不会被文件覆盖。
    apply_to_environment()

    config = {}
    for p in CONFIG_SEARCH_ORDER:
        if p.exists():
            with open(p, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f) or {}
            _cached_path = p
            break

    # Apply environment variable overrides
    for keys, env_var in _ENV_OVERRIDES.items():
        val = os.environ.get(env_var)
        if val is None:
            continue
        if len(keys) == 1:
            config[keys[0]] = val
        elif len(keys) == 2:
            config.setdefault(keys[0], {})[keys[1]] = val

    _cached_config = config
    return config


def get_config_path() -> Path | None:
    """Return the path of the loaded config file (for diagnostics)."""
    if _cached_path is None:
        load_config()
    return _cached_path


def get_wechat_credentials() -> tuple[str, str]:
    """Return (appid, secret). Raises ValueError if missing."""
    cfg = load_config()
    wechat = cfg.get("wechat", {})
    appid = wechat.get("appid", "")
    secret = wechat.get("secret", "")
    if not appid or not secret:
        raise ValueError(
            "WeChat credentials not found. Set WECHAT_APPID + WECHAT_SECRET "
            "environment variables, or configure wechat.appid/secret in config.yaml"
        )
    return appid, secret
