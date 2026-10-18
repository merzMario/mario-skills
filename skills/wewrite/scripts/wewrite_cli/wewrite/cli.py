"""`wewrite` CLI 调度器 —— 把子命令分发到 commands/ 与 toolkit/ 的既有 main()。

设计约束：各命令模块保持独立 argparse（历史上是独立脚本），调度器只做
「子命令名 → 模块」映射并透传其余参数，不重复定义参数。
"""

import importlib
import json
import sys

from . import __version__
from .envconf import apply_to_environment, effective_out_dir, missing_publish_config, resolve
from .paths import home

# 子命令 → (模块, 一句话说明)。模块须提供 main(argv=None) 或 main()。
_COMMANDS = {
    "diagnose": ("wewrite.commands.diagnose", "环境 + 配置自检（降级标记 JSON）"),
    "score": ("wewrite.commands.humanness_score", "写作质量评分（11 项检测）"),
    "content-eval": ("wewrite.commands.content_eval", "汇总编辑判断与初稿修改幅度"),
    "hotspots": ("wewrite.commands.fetch_hotspots", "多平台热点抓取"),
    "search-articles": ("wewrite.commands.search_articles", "搜狗微信搜索公众号文章"),
    "seo": ("wewrite.commands.seo_keywords", "SEO 关键词分析"),
    "stats": ("wewrite.commands.fetch_stats", "微信文章数据回填 history"),
    "learn-edits": ("wewrite.commands.learn_edits", "学习人工修改（diff → lessons）"),
    "learn-theme": ("wewrite.commands.learn_theme", "从公众号文章 URL 学排版主题"),
    "exemplar": ("wewrite.commands.extract_exemplar", "范文风格库（导入 / --list）"),
    "fetch-article": ("wewrite.commands.fetch_article", "公众号文章 URL → Markdown"),
    "llm-write": ("wewrite.commands.llm_write", "混合路由写作（DeepSeek 等出稿）"),
    "similarity": ("wewrite.commands.similarity_check", "多平台版本原创度检查"),
    "run": ("wewrite.commands.run_manager", "独立文章任务：开始 / 恢复 / 完成"),
    "sources": ("wewrite.commands.source_ledger", "记录文章事实来源"),
    "build-playbook": ("wewrite.commands.build_playbook", "从历史语料生成 playbook"),
    "image-gen": ("wewrite.toolkit.image_gen", "AI 图片生成（多 provider fallback）"),
    "validate": ("wewrite.commands.validate_html", "HTML 微信兼容性校验"),
}

# toolkit/cli.py 自带子命令（preview/publish/gallery/themes/image-post/learn-theme），
# 这些名字直接整体透传给它。
_TOOLKIT_PASSTHROUGH = {"preview", "publish", "gallery", "themes", "image-post"}


def _usage() -> str:
    lines = [
        f"wewrite {__version__} — 公众号内容管道 CLI（状态目录: {home()}）",
        "",
        "用法: wewrite <命令> [参数…]",
        "",
        "命令:",
    ]
    for name, (_, desc) in _COMMANDS.items():
        lines.append(f"  {name:<16}{desc}")
    for name in sorted(_TOOLKIT_PASSTHROUGH):
        lines.append(f"  {name:<16}排版工具链（toolkit）")
    lines += [
        "  home            输出状态目录路径",
        "  out-dir         输出产出目录路径（写作产物落在这里）",
        "  config-info     打印每个配置项的值、来源层和搜索路径",
        "  migrate         迁移旧版仓库内状态到状态目录",
        "",
        "任意命令加 --help 看详细参数。",
    ]
    return "\n".join(lines)


def _config_info(rest: list[str]) -> int:
    """`wewrite config-info` —— mario-skills 约定的配置溯源命令。

    用户说「它写到哪个 vault 了」的时候，agent 跑这一条，而不是去猜、
    更不是自己去读 .env。输出是确定的：值、来源层、每个搜索位置是否存在。
    """
    resolved = resolve()
    as_json = "--json" in rest

    out_dir = effective_out_dir(resolved)
    report = {
        "ok": True,
        "state_dir": str(home()),
        "out_dir": out_dir or "<unset — falls back to $WEWRITE_HOME/output>",
        "out_dir_from_vault": bool(out_dir) and not resolved.values.get("WEWRITE_OUT_DIR"),
        "config": {key: resolved.display(key) for key in sorted(resolved.values)},
        "sources": {key: resolved.source_of(key) for key in sorted(resolved.sources)},
        "searched": resolved.searched,
        "publish_ready": not missing_publish_config(resolved),
        "missing_publish_keys": missing_publish_config(resolved),
        "hint": "缺失的键写进 <cwd>/.mario-skills/.env 或 ~/.mario-skills/.env；人跑 `wewrite.sh --init` 建文件",
    }

    if as_json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0

    width = max(len(key) for key in report["config"])
    print("wewrite 配置")
    print(f"  状态目录  {report['state_dir']}")
    print(f"  产出目录  {report['out_dir']}")
    if report["out_dir_from_vault"]:
        print("            （由 VAULT_DIR + WEWRITE_OUT_SUBDIR 拼出）")
    print()
    print("  值:")
    for key, value in report["config"].items():
        print(f"    {key:<{width}}  {value}")
    print()
    print("  来源（优先级从高到低）:")
    for key in report["config"]:
        print(f"    {key:<{width}}  {report['sources'][key]}")
    print()
    print("  搜索路径:")
    for index, entry in enumerate(report["searched"], start=1):
        mark = "found" if entry["exists"] else "missing"
        location = entry["path"] or "-"
        print(f"    [{index}] {entry['layer']:<20} {location}  ({mark})")
    print()
    if report["publish_ready"]:
        print("  公众号凭证: 齐全，可以推草稿箱")
    else:
        missing = ", ".join(report["missing_publish_keys"])
        print(f"  公众号凭证: 缺 {missing} —— 只能生成本地预览")
    return 0


def main() -> None:
    argv = sys.argv[1:]
    if not argv or argv[0] in {"-h", "--help"}:
        print(_usage())
        return
    if argv[0] in {"-V", "--version"}:
        print(__version__)
        return

    cmd, rest = argv[0], argv[1:]

    if cmd == "config-info":
        sys.exit(_config_info(rest))
    if cmd == "home":
        print(home())
        return
    if cmd == "out-dir":
        print(effective_out_dir() or "")
        return
    if cmd == "migrate":
        from .migrate import main as migrate_main
        migrate_main(rest)
        return

    # 真正要干活的命令，先把 .mario-skills/.env 落进 os.environ。
    # 放在 config-info 之后：那条命令报告的是**解析结果**的来源层，
    # 提前 setdefault 会把来源伪装成 process.env。
    apply_to_environment()

    if cmd in _TOOLKIT_PASSTHROUGH:
        from .toolkit import cli as toolkit_cli
        sys.argv = ["wewrite", cmd, *rest]
        toolkit_cli.main()
        return
    if cmd in _COMMANDS:
        module_name, _ = _COMMANDS[cmd]
        module = importlib.import_module(module_name)
        sys.argv = [f"wewrite {cmd}", *rest]
        module.main()
        return

    print(f"未知命令: {cmd}\n\n{_usage()}", file=sys.stderr)
    sys.exit(2)
