#!/usr/bin/env python3
"""Assemble v3 artboards from one shared kit (kit.css + symbols.html) and a
per-board body file, so every board uses identical tokens and components.

Body file header comments:
  <!--title: ...-->  <!--size: WxH-->
optional <style data-extra>...</style> and <script data-vals>...JS returning an object...</script>
usage: build.py <body.html> <out.dc.html>
"""
import re, sys, os

TOOLS = os.path.dirname(os.path.abspath(__file__))
FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter+Tight:wght@400;500;600;700&amp;family=IBM+Plex+Mono:wght@400;500&amp;display=swap">'

PRELUDE = """const H = [10,18,30,22,40,40,34,26,40,40,36,20,14,28,40,40,30,24,38,40,32,18,12,28,40,36,22,10,8,6,12,20,30,24,16,10,8,6,6,6];
    const bars = (n, lit) => H.slice(0, n).map((h, i) => ({ h, c: i < lit ? '#F4F4F2' : '#2A2A2D' }));
    const mini = H.slice(0, 20).map((h) => ({ h: Math.max(4, Math.round(h * 0.75)) }));
    const keys = Array.from({ length: 30 }, (_, i) => ({ i }));"""

def main():
    src, out = sys.argv[1], sys.argv[2]
    body = open(src).read()
    title = re.search(r'<!--title:\s*(.*?)-->', body).group(1).strip()
    w, h = re.search(r'<!--size:\s*(\d+)x(\d+)-->', body).groups()
    extra = ''
    m = re.search(r'<style data-extra>(.*?)</style>', body, re.S)
    if m:
        extra = m.group(1)
        body = body.replace(m.group(0), '')
    vals = ''
    m = re.search(r'<script data-vals>(.*?)</script>', body, re.S)
    if m:
        vals = m.group(1).strip()
        body = body.replace(m.group(0), '')
    body = re.sub(r'<!--(title|size):.*?-->\n?', '', body).strip()
    kit = open(os.path.join(TOOLS, 'kit.css')).read()
    symbols = open(os.path.join(TOOLS, 'symbols.html')).read().strip()
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{FONTS}
<style>
{kit}
{extra}
</style>
</helmet>
<div class="bd" style="width: {w}px; height: {h}px">
{symbols}
{body}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{w},"height":{h}}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    {PRELUDE}
    const custom = (() => {{ {vals} }})() || {{}};
    return Object.assign({{ bars: bars(38, 32), mini, keys }}, custom);
  }}
}}
</script>
</body>
</html>
"""
    open(out, 'w').write(page)

if __name__ == '__main__':
    main()
