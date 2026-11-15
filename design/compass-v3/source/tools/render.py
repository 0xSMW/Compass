#!/usr/bin/env python3
"""Local preview of a .dc.html artboard: evaluates renderVals with node,
expands {{holes}}, <sc-for>, <sc-if> in headless Chrome, screenshots the board
and every .ph phone, and reports overflow/overlap problems per phone.

usage: render.py <file.dc.html> <outdir>
"""
import json, os, re, subprocess, sys, tempfile
from playwright.sync_api import sync_playwright

TOOLS = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.path.join(TOOLS, 'node_modules', '@fontsource')

def font_css():
    out = []
    for w in (400, 500, 600, 700):
        out.append("@font-face{font-family:'Inter Tight';font-weight:%d;src:url('file://%s/inter-tight/files/inter-tight-latin-%d-normal.woff2')}" % (w, FONT_DIR, w))
    for w in (400, 500):
        out.append("@font-face{font-family:'IBM Plex Mono';font-weight:%d;src:url('file://%s/ibm-plex-mono/files/ibm-plex-mono-latin-%d-normal.woff2')}" % (w, FONT_DIR, w))
    return '\n'.join(out)

def render_vals(script):
    js = "class DCLogic{constructor(){this.props={};this.state={};}setState(){}}\n" + script + \
         "\nconst v=new Component().renderVals();console.log(JSON.stringify(v,(k,x)=>typeof x==='function'?undefined:x));"
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as f:
        f.write(js)
        p = f.name
    try:
        return json.loads(subprocess.check_output(['node', p]).decode())
    finally:
        os.unlink(p)

EXPAND_JS = r"""
(vals) => {
  const get = (scope, path) => {
    path = path.trim();
    if (path === 'true') return true;
    if (path === 'false') return false;
    if (/^-?\d/.test(path)) return Number(path);
    return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope);
  };
  const interp = (s, scope) => s.replace(/\{\{([^}]+)\}\}/g, (m, p) => { const v = get(scope, p); return v == null ? '' : String(v); });
  const expand = (node, scope) => {
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === 3) { if (child.nodeValue.includes('{{')) child.nodeValue = interp(child.nodeValue, scope); continue; }
      if (child.nodeType !== 1) continue;
      const tag = child.tagName.toLowerCase();
      if (tag === 'sc-for') {
        const m = (child.getAttribute('list') || '').match(/\{\{([^}]+)\}\}/);
        const list = m ? (get(scope, m[1]) || []) : [];
        const as = child.getAttribute('as') || 'item';
        list.forEach((item, i) => {
          const frag = document.createElement('div');
          frag.innerHTML = child.innerHTML;
          expand(frag, Object.assign({}, scope, { [as]: item, $index: i }));
          while (frag.firstChild) node.insertBefore(frag.firstChild, child);
        });
        child.remove();
      } else if (tag === 'sc-if') {
        const m = (child.getAttribute('value') || '').match(/\{\{([^}]+)\}\}/);
        if (m && get(scope, m[1])) {
          expand(child, scope);
          while (child.firstChild) node.insertBefore(child.firstChild, child);
        }
        child.remove();
      } else {
        for (const a of Array.from(child.attributes)) if (a.value.includes('{{')) child.setAttribute(a.name, interp(a.value, scope));
        expand(child, scope);
      }
    }
  };
  expand(document.body, vals);
}
"""

CHECK_JS = r"""
() => {
  const phones = Array.from(document.querySelectorAll('.ph'));
  return phones.map((ph, i) => {
    const r = ph.getBoundingClientRect();
    const cap = ph.parentElement && ph.parentElement.querySelector('.cap b');
    const name = cap ? cap.textContent : ('phone ' + i);
    const issues = [];
    const els = Array.from(ph.querySelectorAll('*')).filter(e => !e.closest('svg') || e.tagName.toLowerCase() === 'svg');
    for (const e of els) {
      const cs = getComputedStyle(e);
      if (cs.display === 'none' || cs.visibility === 'hidden') continue;
      const b = e.getBoundingClientRect();
      if (b.width === 0 || b.height === 0) continue;
      if (e.closest('[data-allow-overflow]')) continue;
      if (b.bottom > r.bottom - 34 + 0.5 && !e.closest('.keys') && !e.closest('.sheet') && !e.classList.contains('scrim') && !e.closest('[data-safe-ok]'))
        issues.push('below safe area: ' + (e.className || e.tagName) + ' bottom=' + Math.round(b.bottom - r.top));
      if (b.right > r.right + 0.5 || b.left < r.left - 0.5)
        issues.push('horizontal overflow: ' + (e.className || e.tagName) + ' ' + Math.round(b.left - r.left) + '..' + Math.round(b.right - r.left));
      if ((e.scrollWidth > e.clientWidth + 1) && cs.overflowX !== 'visible' && !e.closest('[data-allow-overflow]'))
        issues.push('clipped x: ' + (e.className || e.tagName));
    }
    // text overlapping: leaf text blocks intersecting each other
    const texts = els.filter(e => e.children.length === 0 && e.textContent.trim() && !e.closest('svg'));
    const anchors = Array.from(ph.querySelectorAll('[data-anchor]')).map(a => ({ n: a.getAttribute('data-anchor'), y: Math.round(a.getBoundingClientRect().top - r.top), b: Math.round(a.getBoundingClientRect().bottom - r.top) }));
    for (let a = 0; a < texts.length; a++) for (let c = a + 1; c < texts.length; c++) {
      const A = texts[a].getBoundingClientRect(), C = texts[c].getBoundingClientRect();
      if (texts[a].contains(texts[c]) || texts[c].contains(texts[a])) continue;
      if (A.left < C.right - 1 && C.left < A.right - 1 && A.top < C.bottom - 1 && C.top < A.bottom - 1) {
        if (texts[a].closest('.sheet') && !texts[c].closest('.sheet')) continue;
        if (texts[c].closest('.sheet') && !texts[a].closest('.sheet')) continue;
        issues.push('text overlap: "' + texts[a].textContent.trim().slice(0, 24) + '" / "' + texts[c].textContent.trim().slice(0, 24) + '"');
      }
    }
    return { name, issues: Array.from(new Set(issues)).slice(0, 12), anchors };
  });
}
"""

def main():
    src, outdir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    os.makedirs(outdir, exist_ok=True)
    html = open(src).read()
    helmet = re.search(r'<helmet>(.*?)</helmet>', html, re.S).group(1)
    helmet = re.sub(r'<link[^>]*fonts\.googleapis[^>]*>', '', helmet)
    body = re.search(r'<x-dc>(.*?)</x-dc>', html, re.S).group(1)
    body = body.replace(re.search(r'<helmet>.*?</helmet>', body, re.S).group(0), '')
    script = re.search(r'<script type="text/x-dc"[^>]*>(.*?)</script>', html, re.S).group(1)
    vals = render_vals(script)
    page_html = '<!doctype html><html><head><meta charset="utf-8"><style>%s</style>%s</head><body>%s</body></html>' % (font_css(), helmet, body)
    stem = os.path.basename(src).replace('.dc.html', '')
    tmp = os.path.join(outdir, stem + '.preview.html')
    open(tmp, 'w').write(page_html)
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path='/usr/bin/google-chrome', args=['--allow-file-access-from-files'])
        pg = b.new_page(viewport={'width': 1400, 'height': 1000})
        pg.goto('file://' + tmp)
        pg.evaluate(EXPAND_JS, vals)
        pg.evaluate('document.fonts.ready')
        pg.wait_for_timeout(300)
        root = pg.locator('body > div').first
        root.screenshot(path=os.path.join(outdir, stem + '.png'))
        phones = pg.locator('.ph')
        n = phones.count()
        for i in range(n):
            phones.nth(i).screenshot(path=os.path.join(outdir, '%s-%02d.png' % (stem, i + 1)))
        report = pg.evaluate(CHECK_JS)
        b.close()
    for i, r in enumerate(report):
        flag = 'OK ' if not r['issues'] else '!! '
        print('%s%02d %s' % (flag, i + 1, r['name']))
        for a in r['anchors']:
            print('     anchor %-10s y=%d..%d' % (a['n'], a['y'], a['b']))
        for s in r['issues']:
            print('     - ' + s)

if __name__ == '__main__':
    main()
