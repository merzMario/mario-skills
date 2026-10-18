"""`.mario-skills/.env` 解析 —— mario-skills 全技能共享的唯一配置入口。

沿用 baoyu-skills 的查找纪律（mario-skills CLAUDE.md §"The Shared `.env`
Convention"），四级链，逐键解析：

    1. process env         WEWRITE_OUT_DIR=/x python -m wewrite …
    2. <cwd>/.mario-skills/.env      项目级，压过用户级
    3. ~/.mario-skills/.env          用户级，跨项目
    4. 内置默认值

三条不可让步的规则：

**只解析，绝不 source。** 一个装 API key 的 dotenv 文件一旦被 `source`，
就等于把任意代码执行权交给这个文件。这里按行读，剥一层配对引号，值当字面量存。
`$(...)`、反引号、`;` 都只是字符。

**逐键解析，不是全有或全无。** 只设 `VAULT_DIR` 不该把 `WECHAT_APPID` 重置掉。

**不认识就跳过。** 同一个文件还要服务 diary-writer、dankoe-letters-fetch
等兄弟技能，看到不属于自己的键必须无动于衷 —— 这才让「一个文件服务所有技能」成立。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

# 搜索顺序，索引即优先级（0 最高）
LAYERS = ("process.env", "project .env", "user .env", "built-in default")

# 本技能关心的键 → 内置默认值。兄弟技能的键（VAULT_DIR / OPENCLI_BIN …）
# 会原样出现在同一个文件里，这里不认、不报错、不使用。
_KEY_DEFAULTS: dict[str, str] = {
    # 产出落到 vault 哪里。空 = 跟着 WEWRITE_HOME 走（上游默认行为）
    "WEWRITE_OUT_DIR": "",
    "WEWRITE_OUT_SUBDIR": "output/WeWrite",
    # 状态根（凭证、风格、历史、学习语料）。空 = ~/.wewrite
    "WEWRITE_HOME": "",
    # 微信公众号 API
    "WECHAT_APPID": "",
    "WECHAT_SECRET": "",
    "WECHAT_AUTHOR": "",
    # 图片生成
    "WEWRITE_IMAGE_PROVIDER": "",
    "WEWRITE_IMAGE_API_KEY": "",
    "WEWRITE_IMAGE_MODEL": "",
    # 排版主题
    "WEWRITE_THEME": "professional-clean",
    # 写作模型（可选；不配就由 agent 自己写）
    "WEWRITE_WRITER_API_KEY": "",
    "WEWRITE_WRITER_PROVIDER": "deepseek",
    "WEWRITE_WRITER_BASE_URL": "https://api.deepseek.com",
    "WEWRITE_WRITER_MODEL": "deepseek-chat",
}

# 需要在报告里脱敏的键。--config-info 打这些键的值时只回显长度。
_SECRET_KEYS = {
    "WECHAT_SECRET",
    "WEWRITE_IMAGE_API_KEY",
    "WEWRITE_WRITER_API_KEY",
}


@dataclass
class Resolved:
    """一次解析的结果：值 + 来源层 + 搜索路径存在性。"""

    values: dict[str, str] = field(default_factory=dict)
    sources: dict[str, str] = field(default_factory=dict)
    searched: list[dict[str, object]] = field(default_factory=list)

    def get(self, key: str) -> str:
        return self.values.get(key, "")

    def source_of(self, key: str) -> str:
        return self.sources.get(key, LAYERS[-1])

    def display(self, key: str) -> str:
        """给人看的值。密钥只回显「已设置 / 长度」，不打印明文。"""
        value = self.values.get(key, "")
        if key in _SECRET_KEYS:
            return f"<set, {len(value)} chars>" if value else "<not set>"
        return value or "<unset>"


def project_env_path(cwd: Path | None = None) -> Path:
    """项目级 .env。MARIO_SKILLS_PROJECT_ENV 可改写位置（测试用）。"""
    override = os.environ.get("MARIO_SKILLS_PROJECT_ENV", "").strip()
    if override:
        return Path(override)
    return (cwd or Path.cwd()) / ".mario-skills" / ".env"


def user_env_path() -> Path:
    """用户级 .env。MARIO_SKILLS_ENV 可改写位置。"""
    override = os.environ.get("MARIO_SKILLS_ENV", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".mario-skills" / ".env"


def parse_env_file(path: Path) -> dict[str, str]:
    """读一个 dotenv 文件。解析，不是执行。

    - `KEY=VALUE` 一行一个，只按第一个 `=` 切分，所以值里可以有 `=`
    - 可选的 `export ` 前缀会被接受
    - 配对引号剥一层，用来保住首尾空格
    - 空行和 `#` 注释忽略；同一个键后定义的赢
    - 不认识的键原样带出去 —— 兄弟技能要用
    """
    values: dict[str, str] = {}
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return values

    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def resolve(cwd: Path | None = None) -> Resolved:
    """按四级链逐键解析。不认识的键忽略；只设一个键不影响其他键。"""
    project_file = project_env_path(cwd)
    user_file = user_env_path()

    result = Resolved()
    result.searched = [
        {"layer": "process.env", "path": "process.env", "exists": True},
        {"layer": "project .env", "path": str(project_file), "exists": project_file.is_file()},
        {"layer": "user .env", "path": str(user_file), "exists": user_file.is_file()},
        {"layer": "built-in default", "path": None, "exists": True},
    ]

    project_values = parse_env_file(project_file) if project_file.is_file() else {}
    user_values = parse_env_file(user_file) if user_file.is_file() else {}

    for key, default in _KEY_DEFAULTS.items():
        # process env → project .env → user .env → 内置默认
        # 注意 `in os.environ` 而非真值判断：显式设成空串也是一种决定。
        if key in os.environ:
            result.values[key] = os.environ[key]
            result.sources[key] = LAYERS[0]
        elif key in project_values:
            result.values[key] = project_values[key]
            result.sources[key] = LAYERS[1]
        elif key in user_values:
            result.values[key] = user_values[key]
            result.sources[key] = LAYERS[2]
        else:
            result.values[key] = default
            result.sources[key] = LAYERS[3]

    return result


def apply_to_environment(resolved: Resolved | None = None) -> Resolved:
    """把解析结果写进 os.environ，让下游沿用上游读环境变量的老代码不用改。

    只 setdefault：真正的 process env 优先级最高，不该被文件里的值覆盖。

    产出目录在这里做最后一次加工 —— 用户配的是 `VAULT_DIR=…` 加
    `WEWRITE_OUT_SUBDIR=output/WeWrite`，os.environ 里必须拿到拼好的绝对路径，
    `paths.out_dir()` 才认得出它该往 vault 里写。
    """
    resolved = resolved or resolve()
    for key in _KEY_DEFAULTS:
        value = resolved.values.get(key, "")
        if value:
            os.environ.setdefault(key, value)

    out_dir = effective_out_dir(resolved)
    if out_dir:
        os.environ.setdefault("WEWRITE_OUT_DIR", out_dir)

    return resolved



def lookup(key: str, cwd: Path | None = None) -> str:
    """按同一套四级链查**任意**一个键，不限于本技能自己声明的那些。

    存在的理由：VAULT_DIR 由日记、抓取等兄弟技能拥有，本技能自己不声明它，
    但拼产出目录的时候要用。共用一个查找函数，才不会让两条链慢慢分叉。
    """
    if key in os.environ:
        return os.environ[key]
    project_file = project_env_path(cwd)
    if project_file.is_file():
        project_values = parse_env_file(project_file)
        if key in project_values:
            return project_values[key]
    user_file = user_env_path()
    if user_file.is_file():
        user_values = parse_env_file(user_file)
        if key in user_values:
            return user_values[key]
    return ""


def vault_dir(cwd: Path | None = None) -> str:
    """Vault 根。读兄弟技能拥有的 VAULT_DIR；读不到就返回空串。"""
    return lookup("VAULT_DIR", cwd).strip()


def effective_out_dir(resolved: Resolved | None = None) -> str:
    """最终产出目录。

    优先级：
      WEWRITE_OUT_DIR（绝对路径，原样用）
    → VAULT_DIR + / + WEWRITE_OUT_SUBDIR（相对路径，拼成绝对）
    → 空串（调用方退回 $WEWRITE_HOME/output，即上游默认）

    只在 WEWRITE_OUT_DIR 为空时才去拼 vault 路径 —— 显式的绝对路径永远赢。
    """
    resolved = resolved or resolve()

    explicit = resolved.values.get("WEWRITE_OUT_DIR", "").strip()
    if explicit:
        return explicit

    subdir = resolved.values.get("WEWRITE_OUT_SUBDIR", "").strip().strip("/")
    vault = vault_dir()
    if vault and subdir:
        return str(Path(vault) / subdir)

    return ""


def missing_publish_config(resolved: Resolved) -> list[str]:
    """发布到草稿箱还缺哪些键。空列表 = 凭证齐全。"""
    return [key for key in ("WECHAT_APPID", "WECHAT_SECRET") if not resolved.values.get(key)]

