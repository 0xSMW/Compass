#!/usr/bin/env python3
"""Regenerate Compass/DesignSystem/Icons.xcassets from design/compass-v3/source/tools/symbols.html.

Each <symbol> becomes a template-rendered, vector-preserving SVG image set named
"icon-<id>". `currentColor` is replaced by black; the asset is tinted at runtime
with .foregroundStyle. Run from the repo root: python3 scripts/gen_icons.py
"""
import json, os, re, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'design/compass-v3/source/tools/symbols.html')
OUT = os.path.join(ROOT, 'Compass/DesignSystem/Icons.xcassets')

def main():
    html = open(SRC).read()
    symbols = re.findall(r'<symbol id="([a-z]+)" viewBox="([^"]+)">(.*?)</symbol>', html, re.S)
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, 'Contents.json'), 'w'), indent=2)
    for sid, vb, body in symbols:
        body = body.replace('currentColor', '#000000')
        w, h = vb.split()[2:]
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{vb}">{body}</svg>\n'
        d = os.path.join(OUT, f'icon-{sid}.imageset')
        os.makedirs(d)
        open(os.path.join(d, f'icon-{sid}.svg'), 'w').write(svg)
        json.dump({
            "images": [{"filename": f"icon-{sid}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }, open(os.path.join(d, 'Contents.json'), 'w'), indent=2)
        print('icon-' + sid)

if __name__ == '__main__':
    main()
