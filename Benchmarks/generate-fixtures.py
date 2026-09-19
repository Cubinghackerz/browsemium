#!/usr/bin/env python3
"""Generate the deterministic local benchmark fixtures.

The fixtures intentionally cover different rendering and layout workloads so the
memory benchmark exercises more than one kind of page. They contain no external
resources so results are reproducible offline.
"""

from pathlib import Path

FIXTURES = Path(__file__).parent / "Fixtures"

ARTICLE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Article</title>
<style>body{font:16px/1.6 -apple-system,system-ui;margin:0;padding:32px;max-width:70ch}
h1{font-size:30px;margin:0 0 16px}p{margin:0 0 14px}footer{margin-top:32px;color:#666}</style></head>
<body><h1>Long-form reading fixture</h1>__PARAGRAPHS__<footer>End of article</footer></body></html>"""

DOCS = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Docs</title>
<style>body{font:14px/1.5 ui-monospace,monospace;margin:0;display:flex;min-height:100vh}
nav{width:240px;padding:20px;border-right:1px solid #ddd}main{padding:20px;flex:1}
pre{background:#f4f4f4;padding:12px;overflow:auto}</style></head>
<body><nav>__NAV__</nav><main><h1>Reference</h1>__BLOCKS__</main></body></html>"""

DASHBOARD = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Dashboard</title>
<style>body{margin:0;font:14px -apple-system,system-ui;background:#f7f7f8}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;padding:16px}
.card{background:#fff;border:1px solid #e5e5e7;border-radius:8px;padding:14px}
.metric{font-size:26px;font-weight:600}</style></head>
<body><div class="grid">__CARDS__</div></body></html>"""

GALLERY = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Gallery</title>
<style>body{margin:0;display:grid;grid-template-columns:repeat(6,1fr);gap:4px}
.tile{aspect-ratio:1;background:linear-gradient(135deg,hsl(var(--h),70%,60%),hsl(calc(var(--h) + 40),70%,45%))}</style></head>
<body>__TILES__</body></html>"""

FORM = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Form</title>
<style>body{font:14px -apple-system,system-ui;padding:24px;max-width:520px}
label{display:block;margin:12px 0 4px}input,select,textarea{width:100%;padding:8px;border:1px solid #ccc;border-radius:6px}</style></head>
<body><h1>Application form</h1>__FIELDS__</body></html>"""

LIST = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>List</title>
<style>body{font:14px -apple-system,system-ui;margin:0}
.row{display:flex;gap:12px;padding:10px 16px;border-bottom:1px solid #eee}
.row:nth-child(even){background:#fafafa}</style></head>
<body>__ROWS__</body></html>"""

CANVAS = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Canvas</title>
<style>body{margin:0;background:#111;color:#eee;font:13px -apple-system,system-ui}
canvas{display:block;width:100%;height:80vh}</style></head>
<body><canvas id="c" width="1600" height="900"></canvas>
<script>
const ctx = document.getElementById("c").getContext("2d");
for (let i = 0; i < 2000; i++) {
  ctx.fillStyle = `hsl(${(i * 7) % 360},70%,50%)`;
  ctx.fillRect((i * 13) % 1600, (i * 29) % 900, 12, 12);
}
</script></body></html>"""

MEDIA = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Media</title>
<style>body{margin:0;font:14px -apple-system,system-ui;padding:20px}
video,audio{width:100%;max-width:720px;background:#000}</style></head>
<body><h1>Media fixture (paused)</h1>
<video controls preload="metadata" muted></video>
<p>This fixture intentionally ships no media bytes so the benchmark stays offline and deterministic.</p>
</body></html>"""

LONGDOC = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Long document</title>
<style>body{font:15px/1.7 Georgia,serif;margin:0;padding:32px}
section{margin-bottom:24px}</style></head>
<body><h1>Long document fixture</h1>__SECTIONS__</body></html>"""

REPORT = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Printable report</title>
<style>@page{margin:18mm}body{font:12px/1.5 -apple-system,system-ui;margin:0;padding:24px}
table{width:100%;border-collapse:collapse}td,th{border:1px solid #ccc;padding:6px}</style></head>
<body><h1>Quarterly report</h1><table>__ROWS__</table></body></html>"""


def paragraph(index: int) -> str:
    return (
        "<p>Paragraph %d explains the benchmark intent: measure the browser's steady-state "
        "footprint for a text-heavy document without network variance. It repeats enough "
        "content to force real layout and text shaping work.</p>" % index
    )


def write(name: str, body: str, replacements: dict) -> None:
    for token, value in replacements.items():
        body = body.replace(token, value)
    (FIXTURES / name).write_text(body, encoding="utf-8")


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)

    write(
        "01-article.html",
        ARTICLE,
        {"__PARAGRAPHS__": "".join(paragraph(i) for i in range(1, 121))},
    )
    write(
        "02-docs.html",
        DOCS,
        {
            "__NAV__": "".join("<div>section-%d</div>" % i for i in range(1, 61)),
            "__BLOCKS__": "".join(
                "<h2>API %d</h2><pre>func call%d(_ value: Int) -> Int</pre>" % (i, i) for i in range(1, 81)
            ),
        },
    )
    write(
        "03-dashboard.html",
        DASHBOARD,
        {
            "__CARDS__": "".join(
                '<div class="card"><div>Metric %d</div><div class="metric">%d</div></div>' % (i, i * 37)
                for i in range(1, 49)
            )
        },
    )
    write(
        "04-gallery.html",
        GALLERY,
        {"__TILES__": "".join('<div class="tile" style="--h:%d"></div>' % (i * 11) for i in range(1, 145))},
    )
    write(
        "05-form.html",
        FORM,
        {
            "__FIELDS__": "".join(
                '<label>Field %d</label><input type="text" name="field%d" value="value %d">' % (i, i, i)
                for i in range(1, 41)
            )
        },
    )
    write(
        "06-list.html",
        LIST,
        {
            "__ROWS__": "".join(
                '<div class="row"><span>Row %d</span><span>Status</span><span>Updated %d minutes ago</span></div>'
                % (i, i)
                for i in range(1, 401)
            )
        },
    )
    write("07-canvas.html", CANVAS, {})
    write("08-media.html", MEDIA, {})
    write(
        "09-longdoc.html",
        LONGDOC,
        {"__SECTIONS__": "".join("<section><h2>Section %d</h2>%s</section>" % (i, paragraph(i)) for i in range(1, 101))},
    )
    write(
        "10-report.html",
        REPORT,
        {
            "__ROWS__": "".join(
                "<tr><td>Row %d</td><td>%d</td><td>%d</td></tr>" % (i, i * 3, i * 7) for i in range(1, 201)
            )
        },
    )

    print("Wrote %d fixtures to %s" % (len(list(FIXTURES.glob("*.html"))), FIXTURES))


if __name__ == "__main__":
    main()
