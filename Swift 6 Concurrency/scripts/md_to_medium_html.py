#!/usr/bin/env python3
"""
Convert project markdown to HTML that pastes more reliably into Medium's editor
than raw Markdown (Medium's WYSIWYG editor does not interpret # / ``` / |tables|).
"""
from __future__ import annotations

import re
import sys
from html import escape
from pathlib import Path


def _apply_code_bold_italic(s: str) -> str:
    """Inline `code`, **bold**, *italic* (emphasis may wrap around removed code spans)."""
    vault: list[str] = []

    def ph_code(m: re.Match[str]) -> str:
        vault.append(f"<code>{escape(m.group(1))}</code>")
        return f"\x7fC{len(vault) - 1}\x7f"

    t = re.sub(r"`([^`]+)`", ph_code, s)
    t = escape(t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", t)
    for i in range(len(vault) - 1, -1, -1):
        t = t.replace(f"\x7fC{i}\x7f", vault[i])
    return t


def inline_md_to_html_pre_escaped_logic(text: str) -> str:
    """Full inline: [text](url) (link text may contain `code`), then `code`, **bold**, *italic*."""
    links: list[str] = []

    def link_sub(m: re.Match[str]) -> str:
        inner = _apply_code_bold_italic(m.group(1))
        links.append(f'<a href="{escape(m.group(2), quote=True)}">{inner}</a>')
        return f"\x7fL{len(links) - 1}\x7f"

    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link_sub, text)
    t = _apply_code_bold_italic(t)
    for i in range(len(links) - 1, -1, -1):
        t = t.replace(f"\x7fL{i}\x7f", links[i])
    return t


def is_table_row(line: str) -> bool:
    line = line.strip()
    return line.startswith("|") and line.endswith("|") and "|" in line[1:-1]


def parse_table_row(line: str) -> list[str]:
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    return cells


def render_blockquote_inner(bq_lines: list[str]) -> list[str]:
    """Turn stripped-of-'>' lines into HTML fragments (p, ul)."""
    out: list[str] = []
    j = 0
    while j < len(bq_lines):
        raw = bq_lines[j]
        if raw.strip() == "":
            j += 1
            continue
        if raw.strip().startswith("- "):
            out.append("<ul>")
            while j < len(bq_lines) and bq_lines[j].strip().startswith("- "):
                item = bq_lines[j].strip()[2:].lstrip()
                out.append(f"<li>{inline_md_to_html_pre_escaped_logic(item)}</li>")
                j += 1
            out.append("</ul>")
            continue
        out.append(f"<p>{inline_md_to_html_pre_escaped_logic(raw.strip())}</p>")
        j += 1
    return out


def md_to_html(src: str) -> str:
    lines = src.splitlines()
    html: list[str] = [
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="utf-8">',
        "<title>Swift 6 Concurrency — Medium paste</title>",
        "<style>body{font-family:Georgia,serif;max-width:720px;margin:2rem auto;line-height:1.6;} pre{background:#f6f8fa;padding:1rem;overflow-x:auto;} code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.9em;} blockquote{border-left:4px solid #ccc;margin:1rem 0;padding-left:1rem;color:#444;} table{border-collapse:collapse;width:100%;margin:1rem 0;} th,td{border:1px solid #ddd;padding:0.5rem;text-align:left;}</style>",
        "</head>",
        "<body>",
        "<!-- Open in browser: Select All, Copy, paste into Medium. "
        "If formatting drops, paste into Google Docs first, then copy into Medium. -->",
    ]

    i = 0
    in_code = False
    code_lang = ""
    code_buf: list[str] = []

    def flush_code():
        nonlocal code_buf, code_lang
        body = "\n".join(code_buf)
        lang_attr = f' class="language-{escape(code_lang)}"' if code_lang else ""
        html.append(f"<pre><code{lang_attr}>{escape(body)}</code></pre>")
        code_buf.clear()
        code_lang = ""

    while i < len(lines):
        line = lines[i]

        if line.strip().startswith("```"):
            if not in_code:
                in_code = True
                fence = line.strip()[3:].strip()
                code_lang = fence
                i += 1
                continue
            in_code = False
            flush_code()
            i += 1
            continue

        if in_code:
            code_buf.append(line)
            i += 1
            continue

        stripped = line.strip()
        if stripped == "---":
            html.append("<hr>")
            i += 1
            continue

        # GitHub-style table
        if is_table_row(line) and i + 1 < len(lines) and re.match(r"^\s*\|?[-:\s|]+\|?\s*$", lines[i + 1]):
            _ = parse_table_row(line)  # header row (Topic | Rule of thumb)
            i += 2  # skip separator
            rows: list[list[str]] = []
            while i < len(lines) and is_table_row(lines[i]):
                rows.append(parse_table_row(lines[i]))
                i += 1
            # Medium often strips <table> on paste; use a bullet list (same content).
            html.append("<ul>")
            for row in rows:
                if len(row) >= 2:
                    k = inline_md_to_html_pre_escaped_logic(row[0])
                    v = inline_md_to_html_pre_escaped_logic(row[1])
                    html.append(f"<li><strong>{k}</strong> — {v}</li>")
                else:
                    html.append(f"<li>{inline_md_to_html_pre_escaped_logic(' | '.join(row))}</li>")
            html.append("</ul>")
            continue

        if stripped.startswith(">"):
            bq_lines: list[str] = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                raw = lines[i].strip()
                raw = raw[1:].lstrip()
                bq_lines.append(raw)
                i += 1
            html.append("<blockquote>")
            html.extend(render_blockquote_inner(bq_lines))
            html.append("</blockquote>")
            continue

        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            content = m.group(2)
            tag = f"h{level}"
            html.append(f"<{tag}>{inline_md_to_html_pre_escaped_logic(content)}</{tag}>")
            i += 1
            continue

        if re.match(r"^(\s*)-\s+", line):
            html.append("<ul>")
            while i < len(lines):
                mli = re.match(r"^(\s*)-\s+(.*)$", lines[i])
                if not mli:
                    break
                html.append(f"<li>{inline_md_to_html_pre_escaped_logic(mli.group(2))}</li>")
                i += 1
            html.append("</ul>")
            continue

        if line.strip() == "":
            html.append("<p></p>")
            i += 1
            continue

        html.append(f"<p>{inline_md_to_html_pre_escaped_logic(line.strip())}</p>")
        i += 1

    html.extend(["</body>", "</html>"])
    return "\n".join(html)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    md_path = root / "medium-swift6-concurrency.md"
    out_path = root / "medium-swift6-concurrency-medium-paste.html"
    if len(sys.argv) >= 2:
        md_path = Path(sys.argv[1])
    if len(sys.argv) >= 3:
        out_path = Path(sys.argv[2])
    text = md_path.read_text(encoding="utf-8")
    out_path.write_text(md_to_html(text), encoding="utf-8")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
