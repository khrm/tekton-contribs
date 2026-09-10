#!/usr/bin/env python3
"""Render review.sh CSV output to sortable standalone index.html. Stdlib only.

Usage:
  python3 scripts/render-reviews-html.py reviews.csv public/index.html --orgs tektoncd --days 7
  ./review.sh --format csv | python3 scripts/render-reviews-html.py - public/index.html
"""
import csv
import html
import sys
from datetime import datetime, timezone


def load_rows(path):
    if path == "-":
        text = sys.stdin.read().splitlines()
    else:
        with open(path, newline="") as f:
            text = f.read().splitlines()
    reader = csv.DictReader(text)
    rows = []
    for r in reader:
        try:
            rows.append((
                (r.get("Reviewer") or "").strip(),
                int(r.get("Review Events") or 0),
                int(r.get("Unique PRs") or 0),
                int(r.get("Review Comments") or 0),
            ))
        except ValueError:
            continue
    rows.sort(key=lambda x: x[1], reverse=True)
    return rows


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    csv_path, html_path = sys.argv[1], sys.argv[2]
    orgs = days = ""
    args = sys.argv[3:]
    for i, a in enumerate(args):
        if a == "--orgs" and i + 1 < len(args):
            orgs = args[i + 1]
        if a == "--days" and i + 1 < len(args):
            days = args[i + 1]
    rows = load_rows(csv_path)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    trs = "\n".join(
        f'<tr><td><a href="https://github.com/{html.escape(u)}">{html.escape(u)}</a></td>'
        f"<td>{e}</td><td>{p}</td><td>{c}</td></tr>"
        for u, e, p, c in rows
    ) or '<tr><td colspan="4">No reviews found.</td></tr>'
    subtitle = f"Orgs: {html.escape(orgs or 'tektoncd')} &middot; Last {html.escape(days or '7')} days &middot; Updated {now}"
    page = f"""<!doctype html>
<html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PR Review Stats</title>
<style>body{{font-family:system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem}}table{{border-collapse:collapse;width:100%}}th,td{{border:1px solid #ccc;padding:.4rem .6rem;text-align:left}}th{{cursor:pointer;background:#f4f4f4}}td:nth-child(n+2),th:nth-child(n+2){{text-align:right}}#q{{margin:1rem 0;padding:.4rem;width:100%;box-sizing:border-box}}</style>
<h1>PR Review Stats</h1>
<p>{subtitle}</p>
<input id="q" placeholder="Filter reviewer...">
<table id="t"><thead><tr><th>Reviewer</th><th>Review Events</th><th>Unique PRs</th><th>Review Comments</th></tr></thead>
<tbody>{trs}</tbody></table>
<script>
const t=document.getElementById('t'),q=document.getElementById('q');
q.oninput=()=>{{const s=q.value.toLowerCase();for(const r of t.tBodies[0].rows)r.style.display=r.cells[0].textContent.toLowerCase().includes(s)?'':'none'}};
for(const [i,th] of [...t.tHead.rows[0].cells].entries()){{let a=1;th.onclick=()=>{{const b=[...t.tBodies[0].rows];b.sort((x,y)=>{{const X=x.cells[i].textContent,Y=y.cells[i].textContent;return i? (X-Y)*a : X.localeCompare(Y)*a}});a*=-1;for(const r of b)t.tBodies[0].append(r)}}}}
</script>
"""
    with open(html_path, "w") as f:
        f.write(page)
    print(f"Wrote {html_path} ({len(rows)} reviewers)")


if __name__ == "__main__":
    main()
# ponytail: no pagination/charts, add when reviewers exceed ~500 or trends needed
