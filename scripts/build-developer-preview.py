"""Build explicitly illustrated developer-prompt previews from the public palette."""
import argparse
import html
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
palette = json.loads((ROOT/'palette.json').read_text())
for mode in ('dark','light'):
    p = palette[mode] if mode in palette else palette['variants'][mode]
    def esc(x): return html.escape(x,quote=True)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="900" height="330" viewBox="0 0 900 330" role="img" aria-label="Illustrated Bacumi {mode.title()} developer prompt">
<rect width="900" height="330" rx="16" fill="{p['background']}"/>
<g font-family="ui-monospace, SFMono-Regular, Consolas, monospace" font-size="20">
<text x="30" y="45" fill="{p['foreground']}">BACUMI {mode.upper()} · NATIVE DEVELOPER PROMPT</text>
<text x="30" y="105"><tspan fill="{p['directory']}">~/work/project</tspan><tspan fill="{p['git']}">  git:feature/auth</tspan><tspan fill="{p['muted']}">  +2 ~1 ?3  ahead:1</tspan></text>
<text x="30" y="142" fill="{p['accent']}">&gt;</text>
<text x="30" y="202"><tspan fill="{p['directory']}">~/work/project</tspan><tspan fill="{p['git']}">  git:main</tspan><tspan fill="{p['muted']}">  node:22.0.0  3.2s</tspan></text>
<text x="30" y="239"><tspan fill="{p['error']}">!1</tspan><tspan fill="{p['accent']}"> &gt;</tspan></text>
<text x="30" y="301" fill="{p['muted']}" font-size="14">Illustration · ASCII works without a special font · Git never fetches remotes</text>
</g></svg>
'''
    target = ROOT/'assets'/f'developer-{mode}.svg'
    if args.check:
        if not target.exists() or target.read_text()!=svg: raise SystemExit(f'Stale preview: {target}')
    else: target.write_text(svg)
