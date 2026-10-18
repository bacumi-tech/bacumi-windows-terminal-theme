"""Render reproducible native prompt output, using controlled semantic fixtures."""
import argparse
import html
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unicodedata
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--capture-json');args=parser.parse_args()
selected={'developer-clean','merge-failure','status-unavailable'}
captures=[]
if (ROOT/'lib/developer-prompt.zsh').exists():
    spec=importlib.util.spec_from_file_location('bacumi_native_preview',ROOT/'tests/test_segments.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    for appearance in ('dark','light'):
        for case in module.CASES:
            if case['name'] in selected:
                captures.append({'appearance':appearance,'name':case['name'],'ansi':module.render(case,80,appearance,extra={'SSH_CONNECTION':'','SSH_TTY':''})})
    shell='Zsh'
else:
    pwsh=os.environ.get('BACUMI_PWSH') or shutil.which('pwsh')
    if not pwsh:raise SystemExit('PowerShell is required to capture its native prompt. Set BACUMI_PWSH if needed.')
    script=r'''
$ErrorActionPreference='Stop'
Import-Module (Join-Path $env:BACUMI_PREVIEW_ROOT 'prompt/BacumiPrompt.psd1') -Force
$module=Get-Module BacumiPrompt
$cases=Get-Content (Join-Path $env:BACUMI_PREVIEW_ROOT 'tests/fixtures/prompt-segments.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$output=@()
foreach($appearance in @('Dark','Light')) {
 Enable-BacumiPrompt -Appearance $appearance -ColorMode TrueColor
 foreach($case in $cases) {
  if($case.name -notin @('developer-clean','merge-failure','status-unavailable')) {continue}
  $text=& $module {
   param($c)
   $unknown=$null -ne $c.PSObject.Properties['unavailable'] -and [bool]$c.unavailable
   $g=[pscustomobject]@{branch=$c.branch;detached=$false;unborn=$false;conflicts=$c.conflicts;operation=$c.operation;staged=2;unstaged=1;untracked=3;ahead=1;behind=2;unavailable=$unknown}
   Format-BacumiPrompt -Directory $c.directory -Git $g -Width 80 -Success $c.success -NativeExit $c.exit -Context $c.context -Duration $c.duration
  } $case
  $output+=@{appearance=$appearance.ToLowerInvariant();name=$case.name;ansi=$text}
 }
}
Disable-BacumiPrompt
$output | ConvertTo-Json -Depth 4
'''
    env={**os.environ,'BACUMI_PREVIEW_ROOT':str(ROOT),'TERM':'xterm-256color','NO_COLOR':'','COLORTERM':'truecolor'}
    result=subprocess.run([pwsh,'-NoProfile','-Command',script],env=env,text=True,capture_output=True,check=True,timeout=20)
    captures=json.loads(result.stdout.lstrip('\ufeff'));shell='PowerShell'

if args.capture_json:Path(args.capture_json).write_text(json.dumps(captures,ensure_ascii=False,indent=2)+'\n')
palettes=json.loads((ROOT/'palette.json').read_text())['variants']
ansi_roles=['black','red','green','yellow','blue','magenta','cyan','white','brightBlack','brightRed','brightGreen','brightYellow','brightBlue','brightMagenta','brightCyan','brightWhite']
pattern=re.compile(r'\x1b\[([0-9;]*)m')
def columns(text):return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text)
def row_svg(text,y,palette):
    fg=palette['foreground'];bg=palette['background'];inverse=False;x=30.;parts=[];offset=0
    def chunk(text):
        nonlocal x
        if not text:return
        ink,surface=(bg,fg) if inverse else (fg,bg)
        length=columns(text)*10.
        parts.append(f'<rect x="{x:g}" y="{y-18}" width="{length:g}" height="26" fill="{surface}"/>')
        parts.append(f'<text x="{x:g}" y="{y}" fill="{ink}" xml:space="preserve" textLength="{length:g}" lengthAdjust="spacingAndGlyphs">{html.escape(text.replace(" ", chr(160)))}</text>')
        x+=length
    for match in pattern.finditer(text):
        chunk(text[offset:match.start()]);codes=[int(n or '0') for n in match.group(1).split(';')];i=0
        while i<len(codes):
            c=codes[i]
            if c==0:fg=palette['foreground'];bg=palette['background'];inverse=False
            elif c in (38,48) and i+4<len(codes) and codes[i+1]==2:
                color='#'+''.join(f'{v:02X}' for v in codes[i+2:i+5]);i+=4
                if c==38:fg=color
                else:bg=color
            elif c==39:fg=palette['foreground']
            elif c==49:bg=palette['background']
            elif c==7:inverse=True
            elif c==27:inverse=False
            elif 30<=c<=37:fg=palette['ansi'][ansi_roles[c-30]]
            elif 90<=c<=97:fg=palette['ansi'][ansi_roles[c-90+8]]
            i+=1
        offset=match.end()
    chunk(text[offset:]);return ''.join(parts)
outputs={}
for mode in ('dark','light'):
    p=palettes[mode];rows=[];y=86
    for capture in [c for c in captures if c['appearance']==mode]:
        for line in capture['ansi'].splitlines():rows.append(row_svg(line,y,p));y+=30
        y+=22
    label=f'Bacumi {mode.title()} · native {shell} segments'
    rows.insert(0,f'<text x="30" y="38" fill="{p["foreground"]}" font-size="21">{label}</text>')
    rows.append(f'<text x="30" y="{y+6}" fill="{p["muted"]}" font-size="12">Actual native renderer · controlled 80-column fixtures · emulator visual review pending</text>')
    height=y+35
    outputs[f'assets/developer-{mode}.svg']=f'<svg xmlns="http://www.w3.org/2000/svg" width="860" height="{height}" viewBox="0 0 860 {height}" role="img" aria-label="{label}"><rect width="860" height="{height}" rx="12" fill="{p["background"]}"/><g font-family="monospace" font-size="18">'+''.join(rows)+'</g></svg>\n'
for name,content in outputs.items():
    path=ROOT/name
    if args.check:
        if not path.exists() or path.read_text()!=content:raise SystemExit('Stale native preview: '+name)
    else:path.write_text(content)
print('Native prompt captures verified.' if args.check else 'Rendered native prompt captures.')
