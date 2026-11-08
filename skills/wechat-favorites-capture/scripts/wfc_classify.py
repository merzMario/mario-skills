#!/usr/bin/env python3
"""wfc_classify.py — classify WeChat favorites and emit scrape-ready URL lists.

Input : favorites.json  (the decrypted export from wx-favorites-viz)
Output: classified.json + urls/<category>.txt + an optional markdown digest

The taxonomy lives in data/taxonomy.json next to this script — edit that file
to change how favorites are bucketed, then re-run. No Python changes needed.

Two-stage classification:
  1. STRONG keywords — unambiguous terms that decide the bucket. Title hits
     count x3, description hits x1. URLs are stripped from the description
     first, otherwise "译文地址:http://…" drags the text into the wrong bucket.
  2. WEAK keywords — generic words (工作流 / 管理 / 工具 …). They only break
     ties, or carry a bucket on their own once the score clears the floor.
  3. Items with no signal inherit the dominant bucket of the same source
     within a +/- 2 year window, because a source is usually a column.
  4. OVERRIDES — hand-decided items the keywords cannot express.

Usage
    python3 wfc_classify.py \
        --input  <dataset>/favorites.json \
        --output <dataset>/classified.json \
        --urls-dir <dataset>/urls \
        [--taxonomy data/taxonomy.json] [--md <dataset>/分类明细.md]
"""

import argparse
import collections
import json
import os
import re
import sys
import urllib.parse as up

TITLE_W, DESC_W = 3, 1
WEAK_ONLY_MIN = 3          # minimum score for a weak-only match to stand
URL_RE = re.compile(r"https?://\S+|www\.\S+")
CJK_RE = re.compile(r"[一-鿿]")
# The canonical query keys the scraper keeps. `t` matters: image_detail pages
# live under t=pages/image_detail and dropping it collapses them into a
# different article.
CANON_KEEP = {"__biz", "mid", "idx", "sn", "t"}


def canon(url):
    """Canonical form of an article URL — must match the scraper's canon_url.

    An empty or malformed link returns "" — never a bare "https://". The
    placeholder used to survive into urls/*.txt, where it looked like a real
    article to the scraper.
    """
    url = (url or "").strip().split("#")[0]
    if not url or "://" not in url:
        return ""
    try:
        p = up.urlsplit(url)
        q = up.parse_qsl(p.query, keep_blank_values=False)
        keep = sorted((k, v) for k, v in q if k in CANON_KEEP)
        return up.urlunsplit(("https", p.netloc, p.path, up.urlencode(keep), ""))
    except Exception:
        return url


def strip_urls(text):
    return URL_RE.sub(" ", text)


class Matcher:
    """Keyword matching with per-language rules.

    ASCII keywords match on word boundaries so `java` does not fire inside
    `javascript` and `ai` does not fire inside `email`. CJK has no word
    boundaries, so those keywords additionally match against a whitespace-
    stripped copy — "web 应用" should still hit the keyword "web".
    """

    def __init__(self):
        self._ascii = {}
        self._regex = {}

    def _word_pat(self, kw):
        if kw not in self._ascii:
            if re.fullmatch(r"[a-z0-9 .+\-]+", kw) and kw.strip():
                self._ascii[kw] = re.compile(
                    r"(?<![a-z0-9_])" + re.escape(kw) + r"(?![a-z0-9_])")
            else:
                self._ascii[kw] = None
        return self._ascii[kw]

    def _re_pat(self, kw):
        if kw not in self._regex:
            self._regex[kw] = re.compile(kw[3:])
        return self._regex[kw]

    def hit(self, kw, low, nospace=None):
        if kw.startswith("re:"):
            return self._re_pat(kw).search(low) is not None
        p = self._word_pat(kw)
        if p is None:
            if kw in low:
                return True
            if nospace is not None and CJK_RE.search(kw):
                return kw in nospace
            return False
        if p.search(low):
            return True
        if nospace is not None and CJK_RE.search(kw):
            return kw in nospace
        return False


def load_taxonomy(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def score_table(matcher, text, table):
    """{类目: {关键词: 权重}} -> {类目: 得分}"""
    low = text.lower()
    nospace = re.sub(r"\s+", "", low)
    out = {}
    for cat, kws in table.items():
        total = 0.0
        for kw, w in kws.items():
            if matcher.hit(kw, low, nospace):
                total += w
        out[cat] = total
    return out


def classify_item(item, tax, matcher, src_profile):
    overrides = {int(k): v for k, v in tax.get("overrides", {}).items()}
    iid = item.get("id")
    if iid in overrides:
        return overrides[iid][0], "override"

    # 图片类收藏没有正文可判
    if item.get("type") == 2:
        return "图片与附件（无正文）", "type"

    title = strip_urls(item.get("title") or "")
    desc = strip_urls(item.get("desc") or "")
    t_low, d_low = title.lower(), desc.lower()
    t_ns = re.sub(r"\s+", "", t_low)
    d_ns = re.sub(r"\s+", "", d_low)

    strong, weak = {}, {}
    for cat, kws in tax["strong"].items():
        s = 0.0
        for kw, w in kws.items():
            if matcher.hit(kw, t_low, t_ns):
                s += w * TITLE_W
            elif matcher.hit(kw, d_low, d_ns):
                s += w * DESC_W
        strong[cat] = s
        weak[cat] = score_table(matcher, title + " " + desc,
                                {cat: tax.get("weak", {}).get(cat, {})})[cat]

    best = max(strong, key=lambda k: (strong[k], weak[k]))
    if strong[best] > 0:
        tied = [k for k in strong if strong[k] == strong[best]]
        if len(tied) > 1:
            best = max(tied, key=lambda k: weak[k])
        return best, "strong"

    bw = max(weak, key=lambda k: weak[k])
    if weak[bw] >= WEAK_ONLY_MIN:
        return bw, "weak"

    if src_profile:
        prof = src_profile.get(item.get("source", ""))
        if prof:
            y = int((item.get("timestamp") or "0")[:4] or 0)
            near = collections.Counter()
            for c, n, dy in prof:
                if abs(dy - y) <= 2:
                    near[c] += n
            if near:
                return near.most_common(1)[0][0], "inherited"
    return None, None


def tier_of(item, tax):
    link = item.get("link") or ""
    if not link:
        return "NOLINK"
    if "image_detail" in link:
        return "IMG"
    tiers = tax.get("tiers", {})
    year = int((item.get("timestamp") or "0")[:4] or 0)
    min_year = tiers.get("T1", {}).get("min_year")
    if min_year and year >= min_year:
        return "T1"
    t2_cats = set(tiers.get("T2", {}).get("categories", []))
    if item.get("category") in t2_cats:
        return "T2"
    return "T3"


def build_src_profile(items, tax, matcher):
    """Pre-pass: learn each source's dominant bucket so no-signal items can
    inherit it."""
    prof = collections.defaultdict(list)
    for it in items:
        t_low = strip_urls(it.get("title") or "").lower()
        t_ns = re.sub(r"\s+", "", t_low)
        y = int((it.get("timestamp") or "0")[:4] or 0)
        for cat, kws in tax["strong"].items():
            for kw, w in kws.items():
                if matcher.hit(kw, t_low, t_ns):
                    prof[it.get("source", "")].append((cat, w * TITLE_W, y))
                    break
    return prof


def write_urls(urls_dir, items, tax, tier_filter, limit):
    """One file per category, one canonical URL per line.

    Two artifacts come out of here, and the second one is the important one:

      <category>.txt   the URLs, one per line
      _index.json      URL -> {category, tier, title, timestamp}

    The index is what lets `scrape --tier T2` filter per item instead of
    guessing. An earlier version compared the tier recorded in _manifest.json
    against the requested one, so classify --tier T1 followed by scrape --tier
    T2 silently produced nothing and read like "there is nothing to capture".
    """
    os.makedirs(urls_dir, exist_ok=True)

    # Old runs leave .txt files behind for categories that no longer exist.
    # A stale list would be scraped as if it were current.
    for stale in os.listdir(urls_dir):
        if stale.endswith(".txt"):
            os.remove(os.path.join(urls_dir, stale))

    by_cat = collections.defaultdict(list)
    index = {}
    skipped = {}
    for it in items:
        c = canon(it.get("link"))
        if not c:
            continue
        tier = tier_of(it, tax)
        index[c] = {"category": it.get("category") or "未分类", "tier": tier,
                    "title": it.get("title") or "", "timestamp": it.get("timestamp") or ""}
        # 正文抓取器只认 mp.weixin.qq.com。收藏夹里混着抖音视频页、头条、
        # 51CTO 这类链接——它们进了清单也只会让抓取器空转三次重试然后失败，
        # 白等两分钟。单独记下来，别混进待抓清单。
        if "mp.weixin.qq.com" not in c:
            skipped[c] = {"category": it.get("category") or "未分类", "tier": tier,
                          "title": it.get("title") or "",
                          "reason": "不是微信文章链接，正文抓取器只处理 mp.weixin.qq.com"}
            continue
        if tier_filter and tier_filter != "all" and tier != tier_filter:
            continue
        by_cat[it.get("category") or "未分类"].append(c)

    manifest = {}
    for cat, urls in by_cat.items():
        seen, uniq = set(), []
        for u in urls:
            if u in seen:
                continue
            seen.add(u)
            uniq.append(u)
        if limit and len(uniq) > limit:
            uniq = uniq[:limit]
        safe = cat.replace("/", "-").replace(" ", "")
        path = os.path.join(urls_dir, safe + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(uniq) + ("\n" if uniq else ""))
        manifest[cat] = {"file": os.path.basename(path), "count": len(uniq)}

    # 类目按数量降序写进清单 —— 这个顺序就是 `scrape --limit` 花预算的顺序。
    # 按首次出现顺序（≈ 时间顺序）会让预算先花在最老的类目上，那通常不是用户
    # 想要的。降序让「抓 N 篇」落在最大的那几类上。
    ordered = dict(sorted(manifest.items(), key=lambda kv: -kv[1]["count"]))
    with open(os.path.join(urls_dir, "_manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"tier": tier_filter or "all", "limit": limit,
                   "categories": ordered}, f, ensure_ascii=False, indent=2)
    with open(os.path.join(urls_dir, "_index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
    with open(os.path.join(urls_dir, "_skipped.json"), "w", encoding="utf-8") as f:
        json.dump(skipped, f, ensure_ascii=False, indent=2)
    return ordered, skipped


def write_md(path, items, out, tax, by_cat, by_l1, by_year, by_cat_col):
    l1_of = tax.get("l1_of", {})
    L = ["# 微信收藏分类明细\n",
         f"总计 {out['total']} 条。\n",
         "\n## 一级分布\n\n| 一级类目 | 条数 | 占比 |\n|---|---|---|\n"]
    for k, v in by_l1.most_common():
        L.append(f"| {k} | {v} | {v / out['total'] * 100:.0f}% |")
    L.append("\n## 二级分布\n\n| 二级类目 | 一级 | 条数 | 主导栏目 |\n|---|---|---|---|\n")
    for c, v in by_cat.most_common():
        cols = by_cat_col.get(c)
        top = cols.most_common(1)[0][0] if cols else "—"
        L.append(f"| {c} | {l1_of.get(c, '未分类')} | {v} | {top} |")
    cats = [c for c, _ in by_cat.most_common() if c != "未分类"]
    L.append("\n## 年度 × 类目\n\n| 年份 | " + " | ".join(cats) + " | 合计 |\n|"
             + "---|" * (len(cats) + 2))
    for y, counter in by_year.items():
        L.append(f"| {y} | " + " | ".join(str(counter.get(c, 0)) for c in cats)
                 + f" | {sum(counter.values())} |")
    L.append("\n## 分类清单\n")
    for c, v in by_cat.most_common():
        L.append(f"\n### {c}（{v} 条 · {l1_of.get(c, '未分类')}）\n")
        sub = sorted([i for i in items if (i.get("category") or "未分类") == c],
                     key=lambda i: i.get("timestamp") or "")
        for it in sub:
            t = (it.get("title") or "(无标题)").replace("\n", " ")
            flag = {"inherited": " ⟨来源继承⟩", "override": " ⟨人工判定⟩",
                    "weak": " ⟨弱命中⟩", "type": " ⟨无正文⟩"}
            L.append(f"- {t} · {it.get('timestamp', '')[:10]}"
                     f"{flag.get(it.get('mode'), '')}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser(description="微信收藏分类器 + URL 清单生成")
    ap.add_argument("--input", "-i", required=True, help="favorites.json")
    ap.add_argument("--output", "-o", required=True, help="classified.json")
    ap.add_argument("--urls-dir", help="写出 <分类>.txt URL 清单的目录")
    ap.add_argument("--taxonomy", help="词表 JSON（默认 data/taxonomy.json）")
    ap.add_argument("--md", help="额外写一份 markdown 明细")
    ap.add_argument("--tier", default="all",
                    help="只输出某层：T1 / T2 / T3 / all")
    ap.add_argument("--limit", type=int, default=0, help="每类最多几条（0=不限）")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    tax_path = args.taxonomy or os.path.join(here, "..", "data", "taxonomy.json")
    if not os.path.isfile(tax_path):
        print(json.dumps({"ok": False, "error": "taxonomy_not_found",
                          "path": tax_path}, ensure_ascii=False))
        return 2
    tax = load_taxonomy(tax_path)

    with open(args.input, encoding="utf-8") as f:
        data = json.load(f)
    items = data["items"] if isinstance(data, dict) else data

    matcher = Matcher()
    src_profile = build_src_profile(items, tax, matcher)

    for it in items:
        cat, mode = classify_item(it, tax, matcher, src_profile)
        it["category"] = cat or "未分类"
        it["mode"] = mode or "strong"

    l1_of = tax.get("l1_of", {})
    by_cat = collections.Counter(it["category"] for it in items)
    by_l1 = collections.Counter()
    for c, n in by_cat.items():
        by_l1[l1_of.get(c, "未分类")] += n
    by_year = collections.defaultdict(collections.Counter)
    for it in items:
        by_year[(it.get("timestamp") or "")[:4]][it["category"]] += 1
    by_col = collections.Counter()
    by_cat_col = collections.defaultdict(collections.Counter)
    col_rules = tax.get("columns", {})
    for it in items:
        it["tier"] = tier_of(it, tax)
        if col_rules:
            text = strip_urls(f"{it.get('title', '')} {it.get('desc', '')}")
            scores = score_table(matcher, text, col_rules)
            top = max(scores, key=lambda k: scores[k])
            if scores[top] > 0:
                it["column"] = top
                by_col[top] += 1
                by_cat_col[it["category"]][top] += 1
            else:
                it["column"] = None
        else:
            it["column"] = None

    out = {
        "total": len(items),
        "by_l1": dict(by_l1.most_common()),
        "by_category": dict(by_cat.most_common()),
        "by_year_category": {y: dict(c.most_common()) for y, c in sorted(by_year.items())},
        "by_tier": dict(collections.Counter(it["tier"] for it in items).most_common()),
        "by_column": dict(by_col.most_common()),
        "classify_modes": dict(collections.Counter(it["mode"] for it in items).most_common()),
        "items": [{
            "id": it.get("id"), "title": it.get("title") or "(无标题)",
            "timestamp": it.get("timestamp"), "source": it.get("source"),
            "link": it.get("link"), "category": it["category"],
            "l1": l1_of.get(it["category"], "未分类"), "tier": it["tier"],
            "column": it["column"], "mode": it["mode"],
        } for it in items],
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    manifest = {}
    skipped = {}
    if args.urls_dir:
        manifest, skipped = write_urls(args.urls_dir, items, tax, args.tier, args.limit)

    if args.md:
        write_md(args.md, items, out, tax, by_cat, by_l1, by_year, by_cat_col)

    print(json.dumps({
        "ok": True, "output": args.output, "total": out["total"],
        "by_l1": out["by_l1"], "by_tier": out["by_tier"],
        "by_column": out["by_column"],
        "modes": out["classify_modes"],
        "url_files": {k: v["count"] for k, v in manifest.items()},
        "skipped_not_wechat": len(skipped),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
