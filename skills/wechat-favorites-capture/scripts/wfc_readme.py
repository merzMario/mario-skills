#!/usr/bin/env python3
"""wfc_readme.py — rewrite the dataset README from what is actually on disk.

Two jobs, both mechanical, both previously done by hand:

1. **The articles table.** Counts are measured, never remembered: one .md per
   captured article, body characters after the frontmatter block, CDN image
   references by regex.

2. **The gap accounting.** The single question people ask about a capture is
   "what did NOT make it in, and why". That answer is computable: the URL index
   knows every favorite and its tier, the filesystem knows what landed. The
   difference is the gap — broken down by tier, with the dead ones named.

Usage: wfc_readme.py [dataset-dir]      # defaults to the configured dataset
       wfc_readme.py --check             # report, write nothing (exit 1 if stale)
"""

import json
import os
import pathlib
import re
import sys

FRONT = re.compile(r"\A---\n.*?\n---\n", re.S)
CDN = re.compile(r"https?://mmbiz\.qpic\.cn")

NOTE = {
    "自媒体与商业变现": "小红书/公众号运营、涨粉、变现、标题公式、写作工作台",
    "AI工作流与Agent": "Coze/Dify/n8n 工作流、AI 工具链、Agent 架构、提示词工程",
    "学习与成长": "读书方法、认知书单、主题阅读、系统思维",
    "管理与职场": "传递压力、用人、精力管理、深度思考、周会",
    "工具与效率": "Obsidian、效率工具、命令行、开发者工具",
    "前端与Web开发": "前端框架、构建、浏览器原理",
    "生活与家居": "装修、家居、美食、旅行",
    "投资理财": "基金、股票、房产、保险",
    "银行与金融科技": "银行核心系统、支付、风控",
    "后端与中间件": "数据库、中间件、服务架构",
    "云原生与微服务": "K8s、容器、DevOps、可观测性",
    "大数据与机器学习": "Hadoop/Spark、算法与模型",
    "网络与协议基础": "TCP/IP、DNS、缓存",
}

TIER_NOTE = {
    "T1": "2024 年起的 AI / 新内容（默认抓取层）",
    "T2": "管理、银行、理财、生活家居类",
    "T3": "2014–2023 的旧技术内容",
    "IMG": "图片消息页，正文基本已失效",
}


def dataset_dir() -> pathlib.Path:
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        return pathlib.Path(sys.argv[1]).expanduser()
    here = pathlib.Path(__file__).resolve().parent
    env = here / "wfc_env.sh"
    if env.exists():
        # shell out to the shared resolver so the .env rules stay in one place
        import subprocess
        out = subprocess.run(
            ["bash", "-c", f'. "{env}" >/dev/null 2>&1; wfc_resolve_all; wfc_dataset_dir'],
            capture_output=True, text=True,
        )
        if out.returncode == 0 and out.stdout.strip():
            return pathlib.Path(out.stdout.strip())
    return pathlib.Path.cwd()


def sn(u: str):
    m = re.search(r"sn=([0-9a-f]+)", u or "")
    return m.group(1) if m else None


def slug(u: str):
    m = re.search(r"/s/([A-Za-z0-9_\-]+)", u or "")
    return m.group(1) if m else None


def articles_table(art: pathlib.Path):
    rows = []
    total_n = total_chars = total_imgs = 0
    sources = set()
    for d in sorted(art.iterdir()):
        if not d.is_dir():
            continue
        files = list(d.glob("*.md"))
        if not files:
            continue
        chars = imgs = 0
        for f in files:
            t = f.read_text(encoding="utf-8", errors="replace")
            body = FRONT.sub("", t)
            chars += len(body)
            imgs += len(CDN.findall(body))
            m = re.search(r'^author:\s*"(.*)"', t, re.M)
            if m:
                sources.add(m.group(1))
        rows.append((d.name, len(files), chars, imgs))
        total_n += len(files)
        total_chars += chars
        total_imgs += imgs
    rows.sort(key=lambda r: -r[1])
    out = ["| 目录 | 篇数 | 字数 | 图片 | 内容 |", "|---|---|---|---|---|"]
    for name, n, c, i in rows:
        out.append(f"| `{name}/` | {n} | {c:,} | {i} | {NOTE.get(name, '—')} |")
    out.append(f"| **合计** | **{total_n}** | **{total_chars:,}** | **{total_imgs}** | "
               f"来源 {len(sources)} 个公众号 |")
    return out, total_n


def gap_section(ds: pathlib.Path, art: pathlib.Path):
    """Every favorite that did not become a file, broken down by why."""
    index_path = ds / "urls" / "_index.json"
    if not index_path.exists():
        return None, None
    cidx = json.loads(index_path.read_text(encoding="utf-8"))

    by_sn = {sn(u): u for u in cidx if sn(u)}
    by_slug = {slug(u): u for u in cidx if slug(u)}
    by_title = {}
    for u, v in cidx.items():
        by_title.setdefault(v.get("title", ""), u)

    landed = set()
    for f in art.glob("*/*.md"):
        t = f.read_text(encoding="utf-8", errors="replace")
        gu = re.search(r'^url:\s*"?([^"\n]+)"?', t, re.M)
        gt = re.search(r'^title:\s*"?([^"\n]+)"?', t, re.M)
        u = gu.group(1) if gu else ""
        title = (gt.group(1) if gt else "").strip()
        key = by_sn.get(sn(u)) or by_slug.get(slug(u)) or by_title.get(title)
        if key:
            landed.add(key)

    tiers = {}
    for u, v in cidx.items():
        if "mp.weixin.qq.com" not in u:
            continue
        t = v.get("tier", "?")
        cur = tiers.setdefault(t, {"total": 0, "landed": 0, "miss": []})
        cur["total"] += 1
        if u in landed:
            cur["landed"] += 1
        else:
            cur["miss"].append(v)

    # urls/_failed.json 是跨轮次累积的失败清单（由 wfc_capture.sh 维护）。
    # 有它才能把「抓过、确实抓不到」和「还没轮到抓」分开——不然 200 条没抓过的
    # 旧技术文章和 5 条原文已删除的会混成同一句话。
    failed = {}
    failed_path = ds / "urls" / "_failed.json"
    if failed_path.exists():
        try:
            failed = json.loads(failed_path.read_text(encoding="utf-8"))
        except Exception:
            failed = {}

    skipped = 0
    skip_path = ds / "urls" / "_skipped.json"
    if skip_path.exists():
        skipped = len(json.loads(skip_path.read_text(encoding="utf-8")))

    dead = [(v.get("tier", ""), v) for u, v in failed.items() if u not in landed]

    lines = ["## 抓取缺口", "",
             "收藏库里的每一条去了哪儿——这张表回答「还有什么没进来」。", "",
             "| 类别 | 条数 | 已落盘 | 抓不到 | 还没抓 | 说明 |",
             "|---|---:|---:|---:|---:|---|"]
    for t in ("T1", "T2", "T3", "IMG"):
        if t not in tiers:
            continue
        c = tiers[t]
        d = sum(1 for dt, _ in dead if dt == t)
        un = c["total"] - c["landed"] - d
        lines.append(f"| {t} | {c['total']} | {c['landed']} | {d} | {un} | "
                     f"{TIER_NOTE.get(t, '')} |")
    lines.append(f"| 非微信链接 | {skipped} | 0 | 0 | {skipped} | 抖音/头条/一点资讯/51CTO，"
                 f"抓取器只处理 `mp.weixin.qq.com` |")
    lines.append("| 无链接条目 | 16 | 0 | 0 | 16 | 文本/文件，没有 URL 可抓 |")
    lines.append("")
    lines.append("「抓不到」= 抓过且重试过仍失败 = 原文已删除 / 违规下架 / 私密，**重试无用**；"
                 "「还没抓」= 还没轮到（分层规则拦下的旧内容）。")
    lines.append("")

    if dead:
        lines.append(f"### 抓不到的 {len(dead)} 条")
        lines.append("")
        for t, v in sorted(dead, key=lambda x: x[1].get("timestamp", ""), reverse=True):
            lines.append(f"- `{t}` {v.get('timestamp', '')[:10]} {v.get('category', '')} —— "
                         f"{v.get('title', '') or '（无标题）'}")
        lines.append("")
    else:
        lines.append("当前没有「抓不到」的条目。")
        lines.append("")

    return "\n".join(lines), sum(c["total"] for c in tiers.values())


def main() -> int:
    ds = dataset_dir()
    art = ds / "articles"
    readme = ds / "README.md"
    if not art.is_dir() or not readme.exists():
        print(f"!! 找不到 {art} 或 {readme}", file=sys.stderr)
        return 2

    table, total_n = articles_table(art)
    gap, wx_total = gap_section(ds, art)

    section = """## articles/ — 收藏正文

`articles/{分类}/` 下是收藏文章**正文**（markdown + 图片 CDN URL），目录即分类，
与上面的分类体系一致。

{table}

- 图片保持 `mmbiz.qpic.cn` 的 CDN URL（**不下载**，已实测 0 条本地化）——
  已配 `local-images-plus` 插件排除 `raw/WeChat-Favorites/`，
  需 `obsidian reload` 整库重载才生效（`plugin:reload` 无效）
- **重新抓取走 `wechat-favorites-capture` skill，一条命令**：
  ```bash
  bash ~/.claude/skills/wechat-favorites-capture/scripts/wfc_capture.sh capture --tier T1 --limit 50
  ```
  它会自动判断要不要解密、跑分类、抓正文、出报告，并在开抓之前把浏览器环境修好
  （daemon / profile / 死标签页租约）。`--limit` 是总量预算。
- **批量抓取必须分块**（≤6 篇/块）+ `--delay 20`：连抓十几篇后浏览器会话会整体僵死。
  skill 已经在脚本里处理了这件事
- **失败的条目多半永远抓不到**（原文已删除 / 违规下架 / 作者隐私设置），重试无用。
  汇报时如实说是「原文已不可见」，不要说「抓取失败」
- 另有 67 条 `image_detail` 图片消息页，多数同样已删除/隐私限制，不投抓取资源
""".replace("{table}", "\n".join(table))

    txt = readme.read_text(encoding="utf-8")
    pat = re.compile(r"## articles/ — 收藏正文.*?(?=\n## )", re.S)
    if not pat.search(txt):
        pat = re.compile(r"## articles/ — .*?(?=\n## )", re.S)
    if not pat.search(txt):
        print("!! 找不到 articles/ 段落，未改动", file=sys.stderr)
        return 1
    new_txt = pat.sub(section.rstrip("\n") + "\n", txt)

    # The gap section lives at the END of the file on purpose: the articles
    # section above gets rewritten wholesale, so anything kept inside it would
    # be silently wiped on the next run.
    if gap:
        gap_pat = re.compile(r"\n## 抓取缺口.*?\Z", re.S)
        if gap_pat.search(new_txt):
            new_txt = gap_pat.sub("\n" + gap.rstrip("\n") + "\n", new_txt)
        else:
            new_txt = new_txt.rstrip("\n") + "\n\n" + gap.rstrip("\n") + "\n"

    if "--check" in sys.argv:
        if new_txt != txt:
            print("README 与磁盘不一致（--check，不写）")
            return 1
        print("README 与磁盘一致")
        return 0

    readme.write_text(new_txt, encoding="utf-8")
    print(f"已更新 {readme}  ({total_n} 篇正文, {wx_total} 条微信链接)")
    print("\n".join(table))
    return 0


if __name__ == "__main__":
    sys.exit(main())
