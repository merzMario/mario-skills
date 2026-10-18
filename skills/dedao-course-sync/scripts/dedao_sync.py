#!/usr/bin/env python3
"""得到专栏增量同步（得到精选 / 得到头条）。

为什么不用 2023 那套 dedao-scrape.py 的 init 流程：
    老流程假设目录 URL 只能逐条 click 拿（Vue SPA + pushState），
    全量 580 讲按 2 小时预留。实际上课程列表背后有 JSON 接口，
    一次调用返回 50 讲，`reverse: true` 即倒序，`max_id` 游标翻页。
    所以「先跑两小时初始化」这一步整个没了。

为什么不用 baoyu-fetch 抓正文：
    得到正文由 Vue 客户端渲染，baoyu-fetch 拿到的是空壳（实测 761 字节，
    只剩 <title>）。正文走 `opencli browser extract --selector .article-body`。

用法
    python3 dedao_sync.py list  --course jingxuan [--count 20] [--dry-run]
    python3 dedao_sync.py fetch --course jingxuan [--count 20] [--dry-run]
    python3 dedao_sync.py fetch --course all     [--count 20] [--dry-run]

    --count N   本次要抓的【新】篇数（默认 20）。不够就往回翻页直到凑满
                或列表翻完 —— 不是"取最新 N 条里没抓过的"，那样抓完一轮后
                会永远返回 0 篇。
    --dry-run   只列出会抓哪几篇，不碰浏览器

落盘
    <vault>/raw/Courses-GetIt/<课程名>/YYYY-MM-DD-<slug>.md

图片不在本脚本职责内：正文保留 `![](https://...)` 远程链接即可，Vault 的
`obsidian-local-images-plus` 插件会把它们下载进 assets/ 并自动改写成
`![[...]]` —— 存量 102 篇里的本地图片都是它干的，不是抓取器。

依赖
    opencli（浏览器桥；需 Chrome 已登录得到，且 OpenCLI 扩展已装）
"""
from __future__ import annotations

import argparse
import copy
import datetime
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

VAULT = Path(os.environ.get("DEDAO_VAULT") or
             os.environ.get("VAULT_DIR") or
             (Path.home() / "Documents/Obsidian"))
OUT_SUBDIR = os.environ.get("DEDAO_OUT_SUBDIR") or "raw/Courses-GetIt"
STATE_DIR = Path(os.environ.get("DEDAO_STATE_DIR") or
                 (Path.home() / ".local/share/dedao-course-sync"))
OPENCLI_BIN = os.environ.get("OPENCLI_BIN") or "opencli"

# 失败清单落在这里，不落 skill 目录 —— skill 目录可能被 marketplace 装成
# 只读，而且运行期状态本来就不该混进代码目录。
ERRORS_FILE = STATE_DIR / "dedao-sync-errors.json"

# slug 清洗表按专栏各一份，刻意不合并 —— 历史文件名就是按各自规则生成的
# （得到头条保留 `、` 顿号，得到精选不保留）。改之前先 grep 历史文件名。
SLUG_RE_TOUTIAO = re.compile(r'[\\/:*?"<>|｜：，。？！!·]')
SLUG_RE_JINGXUAN = re.compile(r'[\\/:*?"<>|｜：，。？！“”‘’]')
SLUG_MAX = 80

COURSES = {
    "toutiao": {
        "name": "得到头条",
        "tag": "得到头条",
        "course_id": "nb9L2q1e3OxKBPNsdoJrgN8P0Rwo6B",
        "slug_re": SLUG_RE_TOUTIAO,
        # 正文的开场白锚点，锚点之前的标题/时长/WiFi 提示行全部丢掉
        "body_anchor": r"^(你好|这里是《|各位)",
    },
    "jingxuan": {
        "name": "得到精选",
        "tag": "得到精选",
        "course_id": "b0rNAzaYOj7VyPMs09K8P54m6wlk12",
        "slug_re": SLUG_RE_JINGXUAN,
        "body_anchor": r"^(你好|这里是《|各位)",
    },
}

# 会话名可配，但默认值必须和 ensure_course_page 里的用法保持一致：
# 同一浏览器窗口串行跑两个专栏会互相换掉标签页，正文探针会读到上一篇。
SESSION = os.environ.get("DEDAO_SESSION") or "dedao-sync"
ARTICLE_URL = "https://www.dedao.cn/course/article?id={enid}"
COURSE_URL = "https://www.dedao.cn/course/detail?id={course_id}"
MAX_PAGES = 25          # 25 页 × 50 讲 = 最多回看 1250 讲，防止死循环
PAGE_SIZE = 50          # 接口实测上限；给 100 会返回空列表


# =============================================================================
# 纯函数
# =============================================================================

def slugify(title: str, course: str) -> str:
    """标题 → 文件名 slug。命中字符换成 `-`（`｜` 前的 001 序号靠它隔开），
    连续 `-` 折叠、首尾去掉，超长截到 80。空格原样保留（与老脚本一致）。"""
    if not title:
        return "untitled"
    s = COURSES[course]["slug_re"].sub("-", title)
    s = re.sub(r"-+", "-", s).strip("-")
    return s[:SLUG_MAX] if len(s) > SLUG_MAX else s


def out_dir(course: str) -> Path:
    return VAULT / OUT_SUBDIR / COURSES[course]["name"]


def scan_done_article_ids(course: str) -> set[str]:
    """扫目录里 frontmatter 的 article_id —— 这是去重的唯一依据。

    靠文件名去重不可靠：标题会改，slug 清洗规则也变过；enid 是得到侧的
    永久标识，102 篇存量里 101 篇都有（剩 1 篇是手改的，但 source 链接里
    仍带 enid，见 _fallback_ids）。
    """
    ids: set[str] = set()
    d = out_dir(course)
    if not d.is_dir():
        return ids
    for fp in d.iterdir():
        if fp.suffix != ".md":
            continue
        try:
            text = fp.read_text(encoding="utf-8")
        except OSError:
            continue
        m = re.search(r'^article_id:\s*["\']?([^\s"\'\n]+)["\']?\s*$', text, re.MULTILINE)
        if m:
            ids.add(m.group(1))
            continue
        # 兜底：frontmatter 缺字段的老文件，从 source 链接里捞 enid
        m2 = re.search(r"course/article\?id=([A-Za-z0-9]{16,})", text)
        if m2:
            ids.add(m2.group(1))
    return ids


# 结尾工具条 = 一整行由这些动作词连写而成（如「写笔记划线删除划线复制」）。
# ⚠️ 不要写成「以动作词开头」——「分享一部2018年出版的书…」「收藏了这个想法」
# 这类正常正文句子会被误判成工具条，从中间把文章腰斩（李海鹏 2026-10-01 那篇
# 就这么被砍到 341 字）。判据必须是「整行只有这些字」。
TOOLBAR_RE = re.compile(r"^[写笔记划线删除复制分享收藏点赞评论举报]{4,}$")
# 整行只有一张图片
IMG_ONLY_RE = re.compile(r"^!\[[^\]]*\]\([^)]*\)$|^!\[\[[^\]]*\]\]$")


def strip_preamble(body: str, course: str) -> str:
    """剥掉正文前后的页面元素，只留内容。

    前面：标题回显、时长、「建议 WiFi 环境下播放」、主播自述小标题。
        锚点用各专栏的开场白（得到精选「你好，欢迎来到…」/ 得到头条
        「这里是《得到头条》，我是徐玲。」）。注意得到头条正文里那句
        `## 磊哥逻辑圈,你好` 排在开场白之前，会被一并剥掉 —— 这跟存量
        102 篇的既有形态一致。
    后面：结尾工具条「写笔记划线删除划线复制」和它上面那张图标图。
    锚点找不到就原样返回 —— 宁可留一点噪音，也不要把整篇正文丢掉。
    """
    lines = body.split("\n")
    anchor = re.compile(COURSES[course]["body_anchor"])
    for i, line in enumerate(lines):
        if anchor.match(line.strip()):
            lines = lines[i:]
            break

    for i, line in enumerate(lines):
        if TOOLBAR_RE.match(line.strip()):
            lines = lines[:i]
            break

    # 工具条上面常跟一张图标图，砍掉之后它就成了孤零零的末行
    while lines and (not lines[-1].strip() or IMG_ONLY_RE.match(lines[-1].strip())):
        lines.pop()

    return "\n".join(lines).strip()



def build_frontmatter(article: dict, course: str) -> str:
    cfg = COURSES[course]
    return (
        "---\n"
        f'title: "{article["title"]}"\n'
        f'source: "{ARTICLE_URL.format(enid=article["enid"])}"\n'
        f'course: "{cfg["name"]}"\n'
        f'article_id: "{article["enid"]}"\n'
        f'published: {article["published"]}\n'
        f'created: {datetime.date.today().isoformat()}\n'
        f'tags: [课程, {cfg["tag"]}]\n'
        f'note_type: course_article\n'
        "---\n\n"
    )


# =============================================================================
# opencli 封装
# =============================================================================

def _run(args: list[str], timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run(
        [OPENCLI_BIN, *args], capture_output=True, text=True, timeout=timeout
    )


def _json_out(proc: subprocess.CompletedProcess, what: str):
    """opencli 的成功输出是 JSON；失败时 stderr 是 {ok:false,error:{message}}。
    这里统一把错误翻成异常，别让调用方拿到 None 还往下走。"""
    if proc.returncode != 0:
        raise RuntimeError(f"{what} 失败(rc={proc.returncode}): "
                           f"{(proc.stderr or proc.stdout or '').strip()[:400]}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"{what} 返回的不是 JSON: {proc.stdout[:300]}") from e


def ensure_course_page(course: str) -> None:
    """eval 里的 fetch 是同源的 —— 必须先把标签页停在对应课程页上。"""
    url = COURSE_URL.format(course_id=COURSES[course]["course_id"])
    _run(["browser", SESSION, "open", url], timeout=120)
    time.sleep(2.5)   # SPA 路由 + cookie 就绪，比 sleep 短会拿到空 csrf


# 列表阶段：在页面上下文里翻页收集。每页一次 fetch，翻够 N 篇新的就停。
_JS_TEMPLATE = r"""
(async () => {
  const SEEN = new Set(__SEEN__);
  const CFG = __CFG__;
  const out = [];
  let maxId = 0, pages = 0, total = 0;

  const csrf = decodeURIComponent(
    (document.cookie.match(/csrfToken=([^;]+)/) || [])[1] || '');

  while (out.length < CFG.want && pages < CFG.maxPages) {
    const r = await fetch('/pc/bauhinia/pc/class/purchase/article_list', {
      method: 'POST',
      credentials: 'include',
      headers: {'Content-Type': 'application/json',
                'Xi-Csrf-Token': csrf, 'Xi-DT': 'web'},
      body: JSON.stringify({
        chapter_id: '', count: CFG.pageSize, detail_id: CFG.courseId,
        include_edge: false, is_unlearn: false,
        max_id: maxId, max_order_num: 0,
        reverse: true,               // 倒序 = 最新的在最前
        since_id: 0, since_order_num: 0, unlearn_switch: false
      })
    });
    const j = JSON.parse(await r.text());
    const al = (j.c && j.c.article_list) || [];
    if (!al.length) break;
    total += al.length;
    for (const a of al) {
      if (out.length >= CFG.want) break;
      if (SEEN.has(a.enid)) continue;
      out.push({
        enid: a.enid,
        title: a.title,
        published: new Date(a.publish_time * 1000).toISOString().slice(0, 10),
        summary: a.share_content || '',
        learn_count: a.cur_learn_count || 0
      });
    }
    pages++;
    maxId = al[al.length - 1].id;   // 游标翻页：下一页从这条之后接着
    if (al.length < CFG.pageSize) break;   // 到头了
  }
  return {items: out, pages, total_seen: total, exhausted: out.length < CFG.want};
})()
"""


def list_new(course: str, count: int) -> tuple[list[dict], dict]:
    """翻页直到凑够 `count` 篇没抓过的（最新在前）。返回 (列表, 统计)。"""
    seen = sorted(scan_done_article_ids(course))
    cfg = {
        "courseId": COURSES[course]["course_id"],
        "want": count,
        "pageSize": PAGE_SIZE,
        "maxPages": MAX_PAGES,
    }
    js = (_JS_TEMPLATE
          .replace("__SEEN__", json.dumps(seen))
          .replace("__CFG__", json.dumps(cfg)))
    ensure_course_page(course)
    data = _json_out(_run(["browser", SESSION, "eval", js], timeout=300), "课程列表接口")
    if isinstance(data, str):
        data = json.loads(data)
    return data.get("items", []), {
        "pages": data.get("pages"),
        "total_seen": data.get("total_seen"),
        "exhausted": data.get("exhausted"),
        "already_done": len(seen),
    }


_PROBE_JS = (
    "(() => { const e = document.querySelector('.article-body');"
    " return e ? {n: e.innerText.length, h: e.innerText.slice(0, 60)} : {n: 0, h: ''}; })()"
)

# 正文容器的长度下限。低于它基本可以断定只加载了引子段
# （主播自我介绍那段）就开抓 —— 2026-10-01 李海鹏那篇就是这么只落了 700 字。
MIN_BODY_CHARS = 1200
SETTLE_SECONDS = 1.5      # 连续两次读数间隔
MAX_WAIT_SECONDS = 45


def wait_for_body(session: str, title: str) -> int:
    """等「目标文章的正文」加载完整才返回。

    三个条件缺一不可：
      1. `.article-body` 首行含目标标题 —— 连续抓多篇时，SPA 换页有几百毫秒
         的空窗，这段时间里探针可能读到**上一篇**的 DOM，拿到一个又长又稳的
         长度，光看长度判断会把上一篇的内容当成本篇写下去。
      2. 长度超过下限 —— 得到的正文分段填充，容器会在主播引子段渲染完的瞬间
         就挂上，此时调 extract 会拿到一个「看起来完整」的短文
         （next_start_char 为 null，不报错），但主讲内容还没到。
      3. 连续两次读数相同 —— 内容真的加载完了。
    """
    last, seen_right = -1, False
    deadline = time.time() + MAX_WAIT_SECONDS
    while time.time() < deadline:
        proc = _run(["browser", session, "eval", _PROBE_JS], timeout=60)
        n, head = 0, ""
        if proc.returncode == 0:
            try:
                d = json.loads(proc.stdout or "{}")
                n, head = int(d.get("n") or 0), str(d.get("h") or "")
            except (json.JSONDecodeError, ValueError, TypeError):
                n = 0
        key = title.strip()[:18]
        on_right_article = bool(key) and key in head
        if on_right_article and n >= MIN_BODY_CHARS:
            if n == last:
                return n
            last = n
            seen_right = True
        elif n > 0 and not seen_right:
            last = n
        time.sleep(SETTLE_SECONDS)

    detail = (f"最后读到 {last} 字" if last else ".article-body 始终没出现")
    raise RuntimeError(f"等了 {MAX_WAIT_SECONDS}s 仍不合格：{detail}")


def fetch_body(course: str, enid: str, title: str) -> str:
    """取单篇正文。extract 比 get html 干净：只吐 .article-body 里的内容，
    页面头部/侧栏目录/评论区都不会进来。"""
    url = ARTICLE_URL.format(enid=enid)
    _run(["browser", SESSION, "open", url], timeout=120)
    expected = wait_for_body(SESSION, title)

    chunks, start = [], 0
    while True:
        proc = _run([
            "browser", SESSION, "extract",
            "--selector", ".article-body",
            "--chunk-size", "20000",
            "--start", str(start),
        ], timeout=180)
        data = _json_out(proc, "正文提取")
        if isinstance(data, str):
            data = json.loads(data)
        chunks.append(data.get("content") or "")
        nxt = data.get("next_start_char")
        if nxt is None or nxt <= start:
            break
        start = nxt
    text = "".join(chunks)
    # 完整性校验：extract 拿到的长度应与 DOM 探到的量级一致。
    # 差太多说明分块循环漏了，用一个明显偏低的量报出来，好过写出一篇残稿。
    if len(text) < expected * 0.6:
        raise RuntimeError(f"extract 只拿到 {len(text)} 字，DOM 探到 {expected} 字，疑似分块丢失")
    return text


# =============================================================================
# 子命令
# =============================================================================

def emit(receipt: dict) -> None:
    """stdout 只走这一个 JSON 对象。人读的信息一律在 stderr 上。

    这样调用方可以直接 json.loads(stdout)，不必去解析人话 —— 而"部分失败
    返回 0"这类问题正是人话回执最容易藏住的。
    """
    print(json.dumps(receipt, ensure_ascii=False), flush=True)


def cmd_list(args) -> int:
    items, stats = list_new(args.course, args.count)
    print(f"📖 「{COURSES[args.course]['name']}」已抓 {stats['already_done']} 篇 · "
          f"翻 {stats['pages']} 页 / 见到 {stats['total_seen']} 讲", file=sys.stderr)
    if stats["exhausted"]:
        print(f"   ⚠️ 只凑到 {len(items)} 篇 —— 剩下的讲次已全部抓过（或翻到 "        # noqa: E501
              f"{MAX_PAGES * PAGE_SIZE} 讲上限）", file=sys.stderr)
    for a in items:
        print(f"  {a['published']}  {a['title']}", file=sys.stderr)
    print(f"\n合计 {len(items)} 篇", file=sys.stderr)
    emit({"ok": True, "action": "list", "course": COURSES[args.course]["name"],
          "count": len(items), "items": items, "stats": stats})
    return 0


def cmd_fetch(args) -> int:
    course = args.course
    cfg = COURSES[course]
    target = out_dir(course)

    # --dry-run 在建目录之前就返回：它承诺的是「一个文件都不写」。
    items, stats = list_new(course, args.count)
    print(f"📖 「{cfg['name']}」已抓 {stats['already_done']} 篇 · "
          f"翻 {stats['pages']} 页 / 见到 {stats['total_seen']} 讲 → "
          f"本批待抓 {len(items)} 篇", file=sys.stderr)

    if args.dry_run:
        for a in items:
            print(f"  [试跑] {a['published']}  {a['title']}", file=sys.stderr)
        print(f"\n[试跑] 将写入 {target}（本次不写任何文件）", file=sys.stderr)
        emit({"ok": True, "action": "dry_run", "course": cfg["name"],
              "count": len(items), "items": items, "stats": stats,
              "target": str(target)})
        return 0

    if not items:
        print("✅ 没有新内容。", file=sys.stderr)
        emit({"ok": True, "action": "fetch", "course": cfg["name"],
              "saved": 0, "failed": 0, "skipped": 0, "target": str(target),
              "note": "没有新内容"})
        return 0

    target.mkdir(parents=True, exist_ok=True)

    saved, failed, skipped = 0, [], []
    for i, a in enumerate(items, 1):
        fn = target / f"{a['published']}-{slugify(a['title'], course)}.md"
        if fn.exists():
            # 去重已经按 article_id 做过一遍，所以走到这里只可能是
            # 「确实是新文章，但清洗后的文件名跟存量某篇撞了」。
            # 这不是去重命中，别把它报成"已抓过"。
            skipped.append(fn.name)
            continue
        print(f"  [{i}/{len(items)}] {a['title'][:38]}", file=sys.stderr)
        try:
            body = strip_preamble(fetch_body(course, a["enid"], a["title"]), course)
            if len(body) < MIN_BODY_CHARS * 0.5:
                raise RuntimeError(f"清洗后只剩 {len(body)} 字，疑似抓空或锚点切错")
            fn.write_text(build_frontmatter(a, course) + body + "\n", encoding="utf-8")
            saved += 1
        except Exception as e:                      # 单篇失败不中断整批
            failed.append({"title": a["title"], "enid": a["enid"], "error": str(e)[:200]})
            print(f"      ⚠️ {e}", file=sys.stderr)

    print(f"\n✅ 新抓 {saved} 篇 · 失败 {len(failed)} · 跳过(slug 撞车) {len(skipped)}",  # noqa: E501
          file=sys.stderr)

    errors_path = ""
    if failed:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        ERRORS_FILE.write_text(
            json.dumps(failed, ensure_ascii=False, indent=2), encoding="utf-8")
        errors_path = str(ERRORS_FILE)
        print(f"   失败清单：{ERRORS_FILE}", file=sys.stderr)
    elif ERRORS_FILE.exists():
        # 上一轮有失败、这一轮干净了，留着旧清单只会误导
        ERRORS_FILE.unlink()

    print(f"   落盘：{target}", file=sys.stderr)

    # 任何一篇失败都返回非 0。原来的 `1 if failed and not saved else 0`
    # 会让「20 篇成功 17 篇失败 3 篇」返回 0，cron / launchd 当成功吞掉，
    # 失败的文章从此再也没人重试。
    emit({"ok": not failed, "action": "fetch", "course": cfg["name"],
          "saved": saved, "failed": len(failed), "skipped": len(skipped),
          "skipped_files": skipped, "target": str(target),
          "errors_file": errors_path})
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="得到专栏增量同步")
    ap.add_argument("cmd", choices=["list", "fetch"])
    ap.add_argument("--course", required=True,
                    choices=["jingxuan", "toutiao", "all"])
    ap.add_argument("--count", type=int, default=20,
                    help="本次要抓的新篇数，默认 20")
    ap.add_argument("--dry-run", action="store_true",
                    help="只列清单、不写文件。仍需浏览器：清单来自那个 JSON 接口")
    args = ap.parse_args()

    if args.count < 1:
        emit({"ok": False, "error": "bad_count", "hint": "--count 必须是正整数"})
        return 2

    courses = ["jingxuan", "toutiao"] if args.course == "all" else [args.course]
    rc = 0
    receipts = []
    for c in courses:
        if len(courses) > 1:
            print(f"\n──────── 「{COURSES[c]['name']}」────────", file=sys.stderr)
        sub = copy.copy(args)
        sub.course = c
        try:
            rc |= cmd_list(sub) if args.cmd == "list" else cmd_fetch(sub)
        except RuntimeError as e:
            print(f"❌ {e}", file=sys.stderr)
            receipts.append({"ok": False, "action": args.cmd,
                             "course": COURSES[c]["name"], "error": str(e)[:300]})
            emit({"ok": False, "action": args.cmd, "course": COURSES[c]["name"],
                  "error": str(e)[:300]})
            rc = 1
        except Exception as e:
            traceback.print_exc()
            emit({"ok": False, "action": args.cmd, "course": COURSES[c]["name"],
                  "error": f"{type(e).__name__}: {e}"[:300]})
            rc = 1

    # --course all 时每个专栏各发一次回执，这里再补一条汇总，
    # 让调用方只读一次 stdout 就能拿到总数。
    if len(courses) > 1 and rc == 0:
        emit({"ok": True, "action": "summary", "courses": courses,
              "note": "每个专栏的回执见上面各条"})
    return rc


if __name__ == "__main__":
    sys.exit(main())
