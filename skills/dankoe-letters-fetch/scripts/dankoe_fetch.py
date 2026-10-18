#!/usr/bin/env python3
"""Dan Koe newsletter 增量抓取 —— 把 letters.thedankoe.com 上尚未入库的免费文章
落成 Markdown。

为什么是这个文件而不是纯 prompt：Substack 的 archive API 有四个不直观的约束，
踩错任意一个都会静默少抓或抓错，而它们的症状都不像「报错」：

  1. `limit` 上限 23。填 24/30 会被服务端**静默钳回** 23 条（不报错），填 100
     直接报 `{"errors":[{"msg":"Invalid value"}]}`。所以必须 offset 步进 23
     逐页拉，不能想用大 limit 一次拿全。
  2. archive **列表**里的 `body_html` 恒为 `null`。正文只在单篇端点
     `/api/v1/posts/<slug>` 里有。
  3. 付费墙不能用正文关键词判定。被付费墙截断的正文可能**不含任何显式文案**
     —— 直接断在词中间。关键词法会漏判，而且漏判的方向是"把截断稿当完整稿
     存进库"。唯一可靠的判据是列表里的 `audience` 字段，且它在枚举时就拿到了，
     零额外请求。
  4. Substack 对重发/改写文章加消歧后缀（如 `-ef8`），那是**不同文章**。
     `how-to-launch-into-a-completely-new` 和它的 `-ef8` 版正文不同。去重必须
     slug 精确匹配，不能前缀匹配。

用法
    python3 dankoe_fetch.py list  [--count 10]
    python3 dankoe_fetch.py fetch [--count 10] [--dry-run]

    --count N   本次最多新增几篇。archive 里不足 N 篇新的就全抓并说明。
    --dry-run   只列出会抓哪几篇，**不写任何文件**。仍需网络（archive API 是
                HTTP 接口，不开浏览器），但不碰浏览器也不写盘。

配置
    走 mario-skills 共享的 `.mario-skills/.env`，由 scripts/dankoe_fetch.sh
    解析后以环境变量交给本脚本。直接跑本脚本时每个键都有内置默认值，但推荐走
    shell 入口 —— 那样 --config-info / --init 才能用。

落盘
    $VAULT_DIR/$DANKOE_OUT_SUBDIR/原文/YYYYMMDD-{url-slug}-原文.md

    正文用 `**Source**` 这类粗体键值行，不用 YAML frontmatter —— 这是该目录
    的既有惯例（翻译/ 下的 95 篇也是这个格式），换了会让下游解析脚本失效。

输出契约
    人读信息一律走 stderr，stdout 只输出一个 JSON 回执。
"""
from __future__ import annotations

import argparse
import datetime
import html as html_mod
import json
import os
import re
import subprocess
import sys
import time
import traceback
from pathlib import Path

# =============================================================================
# 配置
# =============================================================================

VAULT = Path(os.environ.get("DANKOE_VAULT") or
             os.environ.get("VAULT_DIR") or
             (Path.home() / "Documents/Obsidian"))
OUT_SUBDIR = os.environ.get("DANKOE_OUT_SUBDIR") or "raw/DanKoe"
STATE_DIR = Path(os.environ.get("DANKOE_STATE_DIR") or
                 (Path.home() / ".local/share/dankoe-letters-fetch"))
OPENCLI_BIN = os.environ.get("OPENCLI_BIN") or "opencli"
SESSION = os.environ.get("DANKOE_SESSION") or "dankoe-letters"

ERRORS_FILE = STATE_DIR / "dankoe-fetch-errors.json"

BASE = "https://letters.thedankoe.com"
ARCHIVE_API = f"{BASE}/api/v1/archive"
POST_API = f"{BASE}/api/v1/posts"
ARTICLE_URL = f"{BASE}/p/{{slug}}"

# 服务端硬上限。填更大不会报错，只会被钳回这个数 —— 所以分页步长必须等于它。
PAGE_SIZE = 23
MAX_PAGES = 40          # 40 × 23 = 920 篇上限，防止接口行为异常时死循环
MIN_BODY_CHARS = 1000   # 低于此判为抓空或半截，不落盘

# 完整文章的 extract 尾部会带这些收尾特征。半截正文（断在词中间）不会有。
# 这也是付费墙截断的兜底判据 —— 比关键词扫正文可靠得多。
TAIL_SIGNATURES = ("Likes", "Restacks", "– Dan", "- Dan", "© 20")

SETTLE_SECONDS = 2.5    # Substack 渐进渲染，跑太早会拿到半截
SELECTOR_TIMEOUT_MS = 12000


# =============================================================================
# 纯函数
# =============================================================================

def source_dir() -> Path:
    return VAULT / OUT_SUBDIR / "原文"


def emitted(receipt: dict) -> None:
    """stdout 只走这一个 JSON 对象。调用方可以直接 json.loads(stdout)。"""
    print(json.dumps(receipt, ensure_ascii=False), flush=True)


def scan_slugs() -> set[str]:
    """扫已入库文件名建 slug 集合 —— 去重的唯一依据。

    文件名格式 `YYYYMMDD-{slug}-原文.md`。用 slug 精确匹配而非前缀匹配：后者
    会把 `-ef8` 消歧版误判成已抓（它们是不同文章）。
    """
    slugs: set[str] = set()
    d = source_dir()
    if not d.is_dir():
        return slugs
    for fp in d.iterdir():
        if fp.suffix != ".md":
            continue
        m = re.match(r"^\d{8}-(.+)-原文\.md$", fp.name)
        if m:
            slugs.add(m.group(1))
    return slugs


def strip_chrome(body: str) -> str:
    """去掉 byline 噪音，保留正文与末尾页脚。

    起点：第一个 `MMM D, YYYY` 日期行之后（那之前是标题/副标题/作者行）。
    末尾 likes/restacks 页脚**原样保留** —— 后续翻译流程不用它，但删了没收益、
    留着可复查。
    """
    lines = body.split("\n")
    start = 0
    for i, line in enumerate(lines):
        if re.match(r"^[A-Z][a-z]{2}\s+\d{1,2},\s+\d{4}\s*$", line.strip()):
            start = i + 1
            break
    out = "\n".join(lines[start:]).strip()
    # 去掉尾部连续空行，但不动 likes/restacks
    return re.sub(r"\n{3,}", "\n\n", out)


def render_note(title: str, subtitle: str, slug: str, published: str, body: str) -> str:
    head = [f"# {title}", ""]
    if subtitle:
        head += [f"### {subtitle}", ""]
    head += [
        f"**Source**: {ARTICLE_URL.format(slug=slug)}",
        f"**Published**: {published}",
        "**Author**: Dan Koe",
        "",
        "---",
        "",
    ]
    return "\n".join(head) + body.rstrip() + "\n"


def looks_complete(text: str) -> bool:
    """尾部有收尾特征才算完整。半截正文会在词中间断掉，没有这些标记。"""
    tail = text[-600:]
    return any(sig in tail for sig in TAIL_SIGNATURES)


def html_to_text(raw: str) -> str:
    """单篇端点的 body_html 去标签。兜底路径才用得到。"""
    h = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", raw, flags=re.S | re.I)
    h = re.sub(r"</(p|h[1-6]|li|blockquote|div|tr)>", "\n\n", h, flags=re.I)
    h = re.sub(r"<br\s*/?>", "\n", h, flags=re.I)
    return html_mod.unescape(re.sub(r"<[^>]+>", "", h))


# =============================================================================
# archive 枚举（纯 HTTP，零浏览器）
# =============================================================================

def _curl_json(url: str, timeout: int = 45):
    proc = subprocess.run(
        ["curl", "-sS", "--max-time", str(timeout), url],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"curl 失败(rc={proc.returncode}): {(proc.stderr or '')[:200]}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"响应不是 JSON: {proc.stdout[:200]}") from exc


def enumerate_archive(max_pages: int = MAX_PAGES) -> list[dict]:
    """分页拉 archive，返回全部条目。空数组即到底。

    offset 步进必须是 PAGE_SIZE(=23)。服务端把更大的 limit 静默钳回 23，
    若按「我请求了多少」步进 offset 会漏页。
    """
    items: list[dict] = []
    seen: set[str] = set()
    for page in range(max_pages):
        offset = page * PAGE_SIZE
        data = _curl_json(f"{ARCHIVE_API}?sort=new&limit={PAGE_SIZE}&offset={offset}")
        batch = data if isinstance(data, list) else (data or {}).get("posts") or []
        if not batch:
            break
        for post in batch:
            slug = post.get("slug")
            if not slug or slug in seen:
                continue
            seen.add(slug)
            items.append({
                "slug": slug,
                "title": post.get("title") or "",
                "subtitle": post.get("subtitle") or "",
                # post_date 是 ISO 时间戳；datetime 属性才是权威日期来源。
                # 两者通常一致，取不到时回落到 post_date 的日期部分。
                "post_date": post.get("post_date") or "",
                "audience": post.get("audience") or "",
            })
    return items


def pick_new(items: list[dict], done: set[str], count: int) -> tuple[list[dict], dict]:
    """挑出要抓的：已抓排除 + 付费墙排除，截到 count 篇。"""
    fresh, already, paywalled = [], 0, 0
    for post in items:
        if post["slug"] in done:
            already += 1
            continue
        # audience 是唯一可靠的付费墙判据。everyone=免费，only_paid=付费墙。
        if post["audience"] != "everyone":
            paywalled += 1
            continue
        fresh.append(post)
    return fresh[:count], {
        "archive_total": len(items),
        "already_in_vault": already,
        "skipped_paywall": paywalled,
        "new_free": len(fresh),
        "taking": min(count, len(fresh)),
        "exhausted": len(fresh) < count,
    }


def iso_date(post: dict) -> str:
    """YYYY-MM-DD。

    优先 post_date 的日期部分。**不做时区换算** —— 页面显示日期（"Sep 20,
    2026"）是本地时区渲染的，会跟 archive 的日期差一天。
    """
    raw = post.get("post_date") or ""
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})", raw)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    return datetime.date.today().isoformat()


# =============================================================================
# 单篇抓取
# =============================================================================

def _run(args: list[str], timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run([OPENCLI_BIN, *args], capture_output=True, text=True, timeout=timeout)


def _parse_opencli(proc: subprocess.CompletedProcess, what: str) -> dict:
    """opencli 成功输出 JSON；失败时 stderr 是 {ok:false,error:{message}}。

    统一翻成异常，别让调用方拿到 None 还往下走。
    """
    if proc.returncode != 0:
        raise RuntimeError(f"{what} 失败(rc={proc.returncode}): "
                           f"{(proc.stderr or proc.stdout or '').strip()[:300]}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{what} 返回的不是 JSON: {proc.stdout[:200]}") from exc


def extract_via_browser(slug: str) -> str:
    """渲染后提取正文。这是主路径。

    渲染等待是必须的：Substack 渐进渲染，跑太早会拿到两种坏结果 ——
    `selector_not_found`（article 还没挂载），或更隐蔽的**半截正文**（断在词
    中间，长得像付费墙截断，实为假阳性）。
    """
    url = ARTICLE_URL.format(slug=slug)
    _run(["browser", SESSION, "open", url], timeout=120)
    try:
        _run(["browser", SESSION, "wait", "selector", "article",
              "--timeout", str(SELECTOR_TIMEOUT_MS)], timeout=60)
        time.sleep(SETTLE_SECONDS)

        chunks, start = [], 0
        for _ in range(12):          # 防分块循环失控
            data = _parse_opencli(_run([
                "browser", SESSION, "extract",
                "--selector", "article",
                "--chunk-size", "30000",
                "--start", str(start),
            ], timeout=180), "正文提取")
            if isinstance(data, str):
                data = json.loads(data)
            chunks.append(data.get("content") or "")
            nxt = data.get("next_start_char")
            if nxt is None or nxt <= start:
                break
            start = nxt

        text = "".join(chunks)
        if len(text) >= MIN_BODY_CHARS and not looks_complete(text):
            # 尾部缺收尾特征：多半是渐进渲染没完成，再等一次重抽
            _run(["browser", SESSION, "wait", "text", "Restacks", "--timeout", "8000"],
                 timeout=40)
            time.sleep(1.5)
            chunks2, start2 = [], 0
            for _ in range(12):
                data = _parse_opencli(_run([
                    "browser", SESSION, "extract",
                    "--selector", "article",
                    "--chunk-size", "30000",
                    "--start", str(start2),
                ], timeout=180), "正文重抽")
                if isinstance(data, str):
                    data = json.loads(data)
                chunks2.append(data.get("content") or "")
                nxt = data.get("next_start_char")
                if nxt is None or nxt <= start2:
                    break
                start2 = nxt
            candidate = "".join(chunks2)
            if len(candidate) > len(text):
                text = candidate
        return text
    finally:
        _run(["browser", SESSION, "close"], timeout=60)


def extract_via_api(slug: str) -> str:
    """兜底：单篇端点的 body_html。浏览器两次仍失败时用。

    免费文章的 body_html 在这个端点是完整的（实测一篇 26831 字符）。
    """
    data = _curl_json(f"{POST_API}/{slug}")
    post = data if isinstance(data, dict) else {}
    return html_to_text(post.get("body_html") or "")


def fetch_body(slug: str) -> tuple[str, str]:
    """返回 (正文, 来源路径)。浏览器为主，API 为兜底。"""
    try:
        text = extract_via_browser(slug)
        if len(text) >= MIN_BODY_CHARS and looks_complete(text):
            return text, "browser"
    except Exception as exc:                        # noqa: BLE001
        print(f"      浏览器路径失败（{exc}），改用单篇 API", file=sys.stderr)

    text = extract_via_api(slug)
    if len(text) < MIN_BODY_CHARS:
        raise RuntimeError(f"兜底后仍只有 {len(text)} 字，疑似付费墙截断或页面改版")
    if not looks_complete(text):
        raise RuntimeError("尾部缺 likes/restacks/落款，判定为不完整")
    return text, "api"


# =============================================================================
# 子命令
# =============================================================================

def cmd_list(args) -> int:
    done = scan_slugs()
    archive = enumerate_archive()
    picked, stats = pick_new(archive, done, args.count)

    print(f"📖 archive {stats['archive_total']} 篇 · 已入库 {stats['already_in_vault']} · "
          f"付费墙 {stats['skipped_paywall']} · 待抓 {stats['new_free']}"
          f" → 取 {stats['taking']}", file=sys.stderr)
    if stats["exhausted"]:
        print("   ⚠️ 已追平 archive（新的免费文章不足 --count）", file=sys.stderr)
    for p in picked:
        print(f"  {iso_date(p)}  {p['title'][:60]}", file=sys.stderr)

    emitted({"ok": True, "action": "list", "count": len(picked),
             "items": [{**p, "date": iso_date(p)} for p in picked],
             "stats": stats, "source_dir": str(source_dir())})
    return 0


def cmd_fetch(args) -> int:
    done = scan_slugs()
    archive = enumerate_archive()
    picked, stats = pick_new(archive, done, args.count)

    print(f"📖 archive {stats['archive_total']} 篇 · 已入库 {stats['already_in_vault']} · "
          f"付费墙 {stats['skipped_paywall']} · 待抓 {stats['new_free']}"
          f" → 取 {stats['taking']}", file=sys.stderr)

    if args.dry_run:
        for p in picked:
            print(f"  [试跑] {iso_date(p)}  {p['title'][:60]}", file=sys.stderr)
        print(f"\n[试跑] 将写入 {source_dir()}（本次不写任何文件）", file=sys.stderr)
        emitted({"ok": True, "action": "dry_run", "count": len(picked),
                 "items": [{**p, "date": iso_date(p)} for p in picked],
                 "stats": stats, "source_dir": str(source_dir())})
        return 0

    if not picked:
        print("✅ 没有新内容。", file=sys.stderr)
        emitted({"ok": True, "action": "fetch", "saved": 0, "failed": 0,
                 "stats": stats, "source_dir": str(source_dir()),
                 "note": "没有新内容"})
        return 0

    target = source_dir()
    target.mkdir(parents=True, exist_ok=True)

    saved, failed, skipped = 0, [], []
    for i, post in enumerate(picked, 1):
        date = iso_date(post)
        fn = target / f"{date.replace('-', '')}-{post['slug']}-原文.md"
        if fn.exists():
            # slug 精确匹配已排除过，走到这里说明该 slug 今天的日期前缀撞了
            # 某个已存文件（极少见：同 slug 改日期重发）。不动它。
            skipped.append(fn.name)
            continue
        print(f"  [{i}/{len(picked)}] {post['title'][:56]}", file=sys.stderr)
        try:
            body, via = fetch_body(post["slug"])
            cleaned = strip_chrome(body)
            if len(cleaned) < MIN_BODY_CHARS:
                raise RuntimeError(f"清洗后只剩 {len(cleaned)} 字")
            fn.write_text(
                render_note(post["title"], post["subtitle"], post["slug"], date, cleaned),
                encoding="utf-8",
            )
            saved += 1
            print(f"      ✓ {len(cleaned)} 字（{via}）", file=sys.stderr)
        except Exception as exc:                    # noqa: BLE001
            failed.append({"slug": post["slug"], "title": post["title"],
                           "error": str(exc)[:200]})
            print(f"      ⚠️ {exc}", file=sys.stderr)

    print(f"\n✅ 新抓 {saved} 篇 · 失败 {len(failed)} · 跳过(同日撞名) {len(skipped)}",
          file=sys.stderr)

    errors_path = ""
    if failed:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        ERRORS_FILE.write_text(json.dumps(failed, ensure_ascii=False, indent=2),
                               encoding="utf-8")
        errors_path = str(ERRORS_FILE)
        print(f"   失败清单：{ERRORS_FILE}", file=sys.stderr)
    elif ERRORS_FILE.exists():
        ERRORS_FILE.unlink()

    print(f"   落盘：{target}", file=sys.stderr)

    # 任何一篇失败都非 0 —— 「抓 10 篇成功 8 篇失败 2 篇」返回 0 会被 cron 吞掉。
    emitted({"ok": not failed, "action": "fetch", "saved": saved,
             "failed": len(failed), "skipped": len(skipped),
             "skipped_files": skipped, "stats": stats,
             "source_dir": str(target), "errors_file": errors_path})
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Dan Koe newsletter 增量抓取")
    ap.add_argument("cmd", choices=["list", "fetch"])
    ap.add_argument("--count", type=int, default=10,
                    help="本次最多新增几篇，默认 10")
    ap.add_argument("--dry-run", action="store_true",
                    help="只列清单、不写文件。仍需网络（HTTP API），但不开浏览器")
    args = ap.parse_args()

    if args.count < 1:
        emitted({"ok": False, "error": "bad_count", "hint": "--count 必须是正整数"})
        return 2

    try:
        return cmd_list(args) if args.cmd == "list" else cmd_fetch(args)
    except RuntimeError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        emitted({"ok": False, "action": args.cmd, "error": str(exc)[:300]})
        return 1
    except Exception as exc:                        # noqa: BLE001
        traceback.print_exc()
        emitted({"ok": False, "action": args.cmd,
                 "error": f"{type(exc).__name__}: {exc}"[:300]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
