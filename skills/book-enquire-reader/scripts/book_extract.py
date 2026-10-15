#!/usr/bin/env python3
"""
book_extract.py — EPUB / TXT / HTML → Markdown, for enquire-mcp indexing.

enquire-mcp indexes Markdown, Canvas, Bases and PDF. It does NOT parse EPUB,
MOBI, TXT or HTML. This script converts those into a single Markdown file with
per-chapter `##` headings, so the extracted text lands in the same retrieval
pool as everything else in the vault.

EPUB and HTML use the standard library only. `ebooklib` / `beautifulsoup4` are
used when importable as an accuracy upgrade, never as a requirement — a missing
optional dependency is not an error here.

Usage:
    python3 book_extract.py BOOK.epub -o out.md [--title "Book Title"]
    python3 book_extract.py BOOK.txt  -o out.md

Exit codes:
    0  wrote the Markdown
    2  unsupported or unreadable input (message on stderr)
    3  extracted nothing usable — the source is likely a scanned/empty file
"""

import argparse
import html
import re
import sys
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from xml.etree import ElementTree

# Chapters are split at `##` so the retrieval chunks align with the book's own
# structure rather than with arbitrary token windows.
CHAPTER_HEADING = "## {}"

MAX_CHARS_PER_CHAPTER = 200_000


# --------------------------------------------------------------------------
# HTML → Markdown
class _MarkdownWriter(HTMLParser):
    """Streaming HTML-to-Markdown.

    Block-oriented: inline text accumulates in a buffer that is flushed to a
    list of finished blocks whenever a block-level boundary appears. That is
    what keeps a paragraph from running into the list item that follows it,
    which the naive accumulate-and-collapse approach gets wrong.

    Tables and images are deliberately lossy — an EPUB table of figures would
    otherwise dominate the chunk budget with no retrieval value.
    """

    SKIP_TAGS = {"script", "style", "head", "nav", "svg", "noscript"}
    HEADINGS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}
    LIST_TAGS = {"ul", "ol"}
    # Tags whose start and end both terminate the current block.
    BLOCK_TAGS = {
        "p", "div", "section", "article", "aside", "blockquote", "figure",
        "pre", "table", "tr", "dl", "dt", "dd", "figcaption", "hr",
    }

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks = []
        self.buf = []
        self.heading_level = None
        self.heading_buf = []
        self.skip_depth = 0
        self.list_stack = []
        self.list_counters = []
        self.in_pre = False
        self.pending_href = ""

    # -- buffer management ------------------------------------------------

    def _emit(self, text):
        if self.heading_level is not None:
            self.heading_buf.append(text)
        else:
            self.buf.append(text)

    def _flush(self):
        """Move the current buffer into a finished block, if it has content."""
        raw = "".join(self.buf)
        self.buf = []
        text = re.sub(r"\s+", " ", raw).strip()
        if not text:
            return
        prefix = ""
        if self.list_stack:
            indent = "  " * (len(self.list_stack) - 1)
            if self.list_stack[-1] == "ol":
                self.list_counters[-1] += 1
                prefix = "{}{}. ".format(indent, self.list_counters[-1])
            else:
                prefix = "{}- ".format(indent)
        self.blocks.append(prefix + text)

    # -- tags -------------------------------------------------------------

    def handle_starttag(self, tag, attrs):
        if self.skip_depth:
            if tag in self.SKIP_TAGS:
                self.skip_depth += 1
            return
        if tag in self.SKIP_TAGS:
            self.skip_depth = 1
            return

        if tag in self.HEADINGS:
            self._flush()
            self.heading_level = self.HEADINGS[tag]
            self.heading_buf = []
            return
        if tag == "br":
            self._emit("  \n")
            return
        if tag in ("strong", "b"):
            self._emit("**")
            return
        if tag in ("em", "i", "cite", "var"):
            self._emit("*")
            return
        if tag == "code" and not self.in_pre:
            self._emit("`")
            return
        if tag == "pre":
            self._flush()
            self.in_pre = True
            self.buf.append("```\n")
            return
        if tag in self.LIST_TAGS:
            self._flush()
            self.list_stack.append(tag)
            self.list_counters.append(0)
            return
        if tag == "li":
            self._flush()
            return
        if tag == "a":
            self._emit("[")
            self.pending_href = dict(attrs).get("href", "")
            return
        if tag == "img":
            alt = dict(attrs).get("alt", "").strip()
            if alt:
                self._emit(alt)
            return
        if tag in self.BLOCK_TAGS:
            self._flush()

    def handle_endtag(self, tag):
        if self.skip_depth:
            if tag in self.SKIP_TAGS:
                self.skip_depth -= 1
            return

        if tag in self.HEADINGS:
            level = self.heading_level
            text = re.sub(r"\*+", "", "".join(self.heading_buf)).strip()
            self.heading_level = None
            self.heading_buf = []
            if text:
                # EPUB h1 is a chapter title; promote it to h2 so every chapter
                # starts at the same depth and chunk boundaries align on it.
                self.blocks.append("#" * min(level + 1, 6) + " " + text)
            return
        if tag in ("strong", "b"):
            self._emit("**")
            return
        if tag in ("em", "i", "cite", "var"):
            self._emit("*")
            return
        if tag == "code" and not self.in_pre:
            self._emit("`")
            return
        if tag == "pre":
            self.buf.append("\n```")
            self.in_pre = False
            self._flush()
            return
        if tag in self.LIST_TAGS:
            self._flush()
            if self.list_stack:
                self.list_stack.pop()
                self.list_counters.pop()
            return
        if tag == "a":
            href = self.pending_href
            self.pending_href = ""
            self._emit("]({})".format(href) if href else "")
            return
        self._flush()

    def handle_data(self, data):
        if self.skip_depth:
            return
        if self.in_pre:
            self.buf.append(data)
            return
        self._emit(data)

    def result(self):
        self._flush()
        # Consecutive list items are joined with a single newline. A blank line
        # between them would make Markdown render a "loose" list, which is
        # visually wrong and wastes tokens on every item.
        out = []
        for block in self.blocks:
            if not block.strip():
                continue
            is_item = bool(re.match(r"^\s*(?:[-*+]|\d+\.)\s", block))
            prev_item = bool(out and re.match(r"^\s*(?:[-*+]|\d+\.)\s", out[-1]))
            if out and is_item and prev_item:
                out[-1] += "\n" + block
            else:
                out.append(block)
        return "\n\n".join(out)


def html_to_markdown(source: str) -> str:
    writer = _MarkdownWriter()
    writer.feed(source)
    writer.close()
    return writer.result().strip()


# --------------------------------------------------------------------------
# EPUB
# --------------------------------------------------------------------------


def _opf_href_to_path(opf_path: str, href: str) -> str:
    """Resolves an OPF-relative href against the OPF's own location in the zip."""
    base = Path(opf_path).parent
    joined = base / href.split("#", 1)[0]
    parts: list = []
    for piece in joined.parts:
        if piece == "..":
            if parts:
                parts.pop()
        elif piece not in (".", ""):
            parts.append(piece)
    return "/".join(parts)


def _localname(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].lower()


def epub_to_markdown(path: Path) -> tuple:
    """Returns (title, markdown). Reads the OPF spine so chapter order is the
    author's order rather than zip-entry order."""
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())

        opf_path = None
        if "META-INF/container.xml" in names:
            container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
            for node in container.iter():
                if _localname(node.tag) == "rootfile":
                    opf_path = node.attrib.get("full-path")
                    if opf_path:
                        break
        if not opf_path:
            candidates = [n for n in names if n.lower().endswith(".opf")]
            if not candidates:
                raise ValueError("no OPF package document found in the EPUB")
            opf_path = candidates[0]

        package = ElementTree.fromstring(archive.read(opf_path))

        title = ""
        manifest = {}
        spine = []
        for node in package.iter():
            tag = _localname(node.tag)
            if tag == "title" and not title:
                title = (node.text or "").strip()
            elif tag == "item":
                item_id = node.attrib.get("id")
                href = node.attrib.get("href")
                media = node.attrib.get("media-type", "")
                if item_id and href:
                    manifest[item_id] = (media, href)
            elif tag == "itemref":
                idref = node.attrib.get("idref")
                if idref:
                    spine.append(idref)

        chapters = []
        if spine:
            for idref in spine:
                entry = manifest.get(idref)
                if not entry:
                    continue
                media, href = entry
                if "html" not in media.lower():
                    continue
                member = _opf_href_to_path(opf_path, href)
                if member not in names:
                    continue
                raw = archive.read(member).decode("utf-8", errors="replace")
                body = html_to_markdown(raw)
                if body.strip():
                    chapters.append(body)
        else:
            # No usable spine: fall back to every XHTML in the archive.
            for member in sorted(n for n in names if n.lower().endswith((".xhtml", ".html", ".htm"))):
                raw = archive.read(member).decode("utf-8", errors="replace")
                body = html_to_markdown(raw)
                if body.strip():
                    chapters.append(body)

    if not chapters:
        return title, ""

    # A chapter that already opens with its own heading keeps it — an EPUB's
    # <h1> is usually the real chapter title, which beats a positional label.
    # Only headingless chapters get a synthesised boundary, so the retrieval
    # chunks still land on chapter starts either way.
    parts = []
    for i, body in enumerate(chapters, 1):
        if re.match(r"^#{1,6}\s", body):
            parts.append(body)
        else:
            parts.append(CHAPTER_HEADING.format(f"Chapter {i}") + "\n\n" + body)
    return title, "\n\n".join(parts)


# --------------------------------------------------------------------------
# TXT
# --------------------------------------------------------------------------

CHAPTER_PATTERNS = [
    re.compile(r"^\s*(?:第[零一二三四五六七八九十百千0-9]+[章回节卷部篇].{0,40})\s*$"),
    re.compile(r"^\s*(?:chapter|CHAPTER|Chapter)\s+[\divxlcIVXLC]+[^\n]{0,60}$"),
    re.compile(r"^\s*(?:CHAPTER|Chapter)\s+[A-Z]\b[^\n]{0,60}$"),
]


def txt_to_markdown(raw: str) -> str:
    """Splits on chapter markers when present, otherwise into fixed-size blocks."""
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")

    marks = [i for i, line in enumerate(lines)
             if any(p.match(line) for p in CHAPTER_PATTERNS)]

    sections = []
    if len(marks) >= 2:
        if marks[0] > 0:
            head = "\n".join(lines[: marks[0]]).strip()
            if len(head) > 200:
                sections.append(("Front Matter", head))
        for idx, start in enumerate(marks):
            end = marks[idx + 1] if idx + 1 < len(marks) else len(lines)
            title = lines[start].strip()
            body = "\n".join(lines[start + 1: end]).strip()
            if body:
                sections.append((title, body))
    else:
        chunk = 20_000
        text = "\n".join(lines).strip()
        for start in range(0, len(text), chunk):
            piece = text[start: start + chunk]
            if piece.strip():
                sections.append(("Part {}".format(start // chunk + 1), piece))

    if not sections:
        return ""

    return "\n\n".join(CHAPTER_HEADING.format(t) + "\n\n" + b for t, b in sections)


# --------------------------------------------------------------------------
# MOBI
# --------------------------------------------------------------------------


def mobi_to_markdown(path: Path) -> tuple:
    """MOBI is a binary container; conversion needs an external tool.

    Tries the converters users already tend to have, in order. Returns
    (title, markdown); markdown is empty when no converter is available, and
    the caller turns that into an actionable message rather than a stack trace.
    """
    import shutil
    import subprocess
    import tempfile

    for tool in ("ebook-convert", "kindlegen"):
        binary = shutil.which(tool)
        if not binary:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / (path.stem + ".epub")
            try:
                subprocess.run(
                    [binary, str(path), str(out)],
                    check=True, capture_output=True, timeout=300,
                )
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                continue
            if out.exists():
                title, markdown = epub_to_markdown(out)
                return title, markdown

    return "", ""


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def extract(path: Path) -> tuple:
    suffix = path.suffix.lower()

    if suffix == ".epub":
        return epub_to_markdown(path)
    if suffix in (".txt", ".text"):
        return "", txt_to_markdown(path.read_text(encoding="utf-8", errors="replace"))
    if suffix in (".html", ".htm", ".xhtml"):
        return "", html_to_markdown(path.read_text(encoding="utf-8", errors="replace"))
    if suffix in (".mobi", ".azw", ".azw3", ".prc"):
        return mobi_to_markdown(path)

    raise ValueError("unsupported format: {}".format(suffix or "(no extension)"))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Convert EPUB/TXT/HTML/MOBI to Markdown for enquire-mcp indexing"
    )
    parser.add_argument("book", help="path to the book file")
    parser.add_argument("-o", "--out", help="output Markdown path (default: stdout)")
    parser.add_argument("--title", help="override the book title in the frontmatter")
    args = parser.parse_args(argv)

    path = Path(args.book).expanduser()
    if not path.is_file():
        print("error: not a readable file: {}".format(path), file=sys.stderr)
        return 2

    try:
        title, markdown = extract(path)
    except (zipfile.BadZipFile, ElementTree.ParseError, KeyError, ValueError) as exc:
        print("error: could not parse {}: {}".format(path.name, exc), file=sys.stderr)
        return 2

    if not markdown.strip():
        if path.suffix.lower() in (".mobi", ".azw", ".azw3", ".prc"):
            print(
                "error: MOBI conversion needs an external tool. Install calibre "
                "(`brew install calibre`, provides ebook-convert) or convert the "
                "file to EPUB first, then re-run.",
                file=sys.stderr,
            )
        else:
            print(
                "error: extracted 0 characters from {} — the file is likely empty, "
                "encrypted, or a scanned image with no text layer.".format(path.name),
                file=sys.stderr,
            )
        return 3

    title = args.title or title or path.stem
    safe_title = title.replace('"', "'")
    document = (
        "---\n"
        'title: "{}"\n'.format(safe_title)
        + "source: \"{}\"\n".format(path.name)
        + "extracted_by: book-enquire-reader\n"
        + "---\n\n"
        + markdown.strip()
        + "\n"
    )

    if args.out:
        out_path = Path(args.out).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(document, encoding="utf-8")
        print('{{"ok":true,"action":"extract","path":"{}","chars":{}}}'.format(
            out_path, len(document)))
    else:
        sys.stdout.write(document)
    return 0


if __name__ == "__main__":
    sys.exit(main())