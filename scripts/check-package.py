"""Smoke-test the actual release archive, using isolated installation destinations."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile
import zipfile
ROOT = Path(__file__).resolve().parents[1]
NAME = 'bacumi-windows-terminal-theme'
VERSION = (ROOT/'VERSION').read_text().strip()
archive = ROOT/'out'/f'{NAME}-{VERSION}.zip'
assert (ROOT/'out/SHA256SUMS').read_text().split()[0] == hashlib.sha256(archive.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='bacumi archive ') as temporary:
    target = Path(temporary)
    with zipfile.ZipFile(archive) as package:
        assert not any(name.lower().endswith(('.ttf','.otf')) for name in package.namelist()), 'Font binary bundled'
        assert all(not Path(name).is_absolute() and '..' not in Path(name).parts for name in package.namelist())
        package.extractall(target)
    source = target/f'{NAME}-{VERSION}'
    assert (source/'fonts/Apache-2.0.txt').is_file()
    if 'oh-my-zsh' in NAME:
        custom = target/'custom location'
        command = ['sh',str(source/'install.sh'),'--custom-dir',str(custom)]
        subprocess.run(command,check=True)
        subprocess.run(['zsh','-fc','source "$1"; _bacumi_developer_precmd; print -rP -- "$PROMPT"','zsh',str(custom/'themes/bacumi/bacumi-developer-dark.zsh-theme')],check=True, env={**os.environ,'TERM':'dumb'})
        subprocess.run(command+['--uninstall'],check=True)
    else:
        pwsh = os.environ.get('BACUMI_PWSH') or shutil.which('pwsh')
        if not pwsh: raise SystemExit('Set BACUMI_PWSH to verify the PowerShell release archive')
        install = source/'Install-Prompt.ps1'
        modules = target/'modules location'
        subprocess.run([pwsh,'-NoProfile','-File',str(install),'-ModuleRoot',str(modules)],check=True)
        module = modules/'BacumiPrompt/BacumiPrompt.psd1'
        env = {**os.environ,'BACUMI_TEST_MODULE':str(module)}
        subprocess.run([pwsh,'-NoProfile','-Command','Import-Module $env:BACUMI_TEST_MODULE; Enable-BacumiPrompt -ColorMode Plain; prompt; Disable-BacumiPrompt'],check=True,env=env)
        subprocess.run([pwsh,'-NoProfile','-File',str(install),'-ModuleRoot',str(modules),'-Uninstall'],check=True)
print(f'Extracted release verified: {archive.name}; no font binaries bundled.')
