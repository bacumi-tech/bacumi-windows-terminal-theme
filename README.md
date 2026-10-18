<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icons/icon-dark-128.png">
    <img src="assets/icons/icon-light-128.png" width="96" height="96" alt="Bacumi for Windows Terminal">
  </picture>
  <h1>Bacumi for Windows Terminal</h1>
  <p>Two coordinated color schemes. One familiar workspace.</p>
  <p>
    <a href="https://github.com/bacumi-tech/bacumi-windows-terminal-theme/releases/tag/v0.1.1">Download 0.1.1 preview</a> ·
    <a href="#installation">Installation</a> ·
    <a href="BRAND.md">Brand and icons</a> ·
    <a href="LICENSE">MIT license</a>
  </p>
</div>

Bacumi Dark pairs a Graphite background with warm accents. Bacumi Light brings
the same color roles to an Off-White workspace. Both include a complete ANSI
palette for command output, with sage greens, quiet blues and Amber focus.

**Preview release.** Automated scheme and installer checks run on GitHub Actions.
Native Windows Terminal visual review is still pending; see [validation](VALIDATION.md).

## Preview

<table>
  <tr><th>Bacumi Dark</th><th>Bacumi Light</th></tr>
  <tr>
    <td width="50%"><img src="assets/bacumi-dark.svg" width="400" alt="Illustrated Bacumi Dark terminal palette"></td>
    <td width="50%"><img src="assets/bacumi-light.svg" width="400" alt="Illustrated Bacumi Light terminal palette"></td>
  </tr>
</table>

Illustrated palette previews, not native Terminal screenshots. Select either
scheme for your PowerShell, Command Prompt or WSL profile; the profile's shell,
font and keybindings stay as configured.

## Installation

### Requirements

- Windows with Windows Terminal supporting JSON fragment extensions.
- Windows PowerShell 5.1 or PowerShell 7 to run the installer.

Installation is per user and requires no administrator access, Git or package manager.

### 1. Download and extract

Download [bacumi-windows-terminal-theme-0.1.1.zip](https://github.com/bacumi-tech/bacumi-windows-terminal-theme/releases/download/v0.1.1/bacumi-windows-terminal-theme-0.1.1.zip)
from the [GitHub release](https://github.com/bacumi-tech/bacumi-windows-terminal-theme/releases/tag/v0.1.1).
The release also includes `SHA256SUMS`. From your download folder, calculate
the ZIP's SHA-256 and compare it with the entry in that checksum file:

```powershell
Get-FileHash .\bacumi-windows-terminal-theme-0.1.1.zip -Algorithm SHA256
```

Extract the ZIP and open PowerShell in the extracted folder containing `Install.ps1`.

### 2. Install both appearances

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The execution-policy option applies only to this installer process. Both schemes
are added through a native fragment at:

```text
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Bacumi\bacumi.json
```

The installer preserves `settings.json` and your existing profile selections.
Use `-WhatIf` to preview its actions or `-FragmentRoot 'C:\path\to\Fragments'`
for a custom fragment directory.

### 3. Select your scheme

Reopen Windows Terminal. Go to **Settings → your profile → Appearance → Color
scheme**, choose **Bacumi Dark** or **Bacumi Light**, and save.

To follow the application's Dark/Light appearance on compatible Terminal
versions, add this property to your existing profile in `settings.json`:

```json
"colorScheme": {
  "dark": "Bacumi Dark",
  "light": "Bacumi Light"
}
```

### Manual installation

Copy [fragments/bacumi.json](fragments/bacumi.json) into a `Bacumi` folder under
the fragment directory above. Alternatively, merge the individual
[Dark](schemes/bacumi-dark.json) and [Light](schemes/bacumi-light.json) objects into
your settings' `schemes` array. Select the scheme in your profile afterward.

Manage manual copies manually. The installer protects folders it does not own.

## Update and uninstall

**Update:** download and extract a newer release, then run its installer again.
If an installed Bacumi file has local edits, installation stops so you can back
up or move your custom copy first. Keep personal schemes under separate names.

**Uninstall:** from the extracted release folder, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

Pass the same `-FragmentRoot` if you used a custom location. Select another scheme
if a profile still refers to Bacumi. Removal preserves unrelated files. For a
manual installation, delete the fragment you copied or remove the scheme objects
you added to your settings.

## Brand and artwork

The themes follow Bacumi Brand v1.0's approved editor palette. The companion
[Oh My Zsh theme](https://github.com/bacumi-tech/bacumi-oh-my-zsh-theme) uses the
same palette revision for coordinated shell prompts under WSL.

[Product artwork](assets/icons/) includes Dark/Light SVG masters and transparent
PNGs from 16 to 1024 px, with [provenance](assets/icons/provenance.json). The icons
are available for documentation, listings and shortcuts. Installing a color
scheme does not replace the Windows Terminal application icon.

Read [BRAND.md](BRAND.md) for color roles, icon rationale and reproduction details.

## Development

<details>
<summary>Build, verify and contribute</summary>

Use a source checkout with Python 3.10+. Build and validation use the standard
library and do not require a private Bacumi repository.

```sh
python3 scripts/build.py --check
python3 scripts/build-icons.py --check
python3 scripts/check-brand.py
python3 -m unittest discover -s tests -v
python3 scripts/package.py
```

On Windows, verify installation and removal in temporary directories:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\install.Tests.ps1
```

Edit `palette.json`, then run `python3 scripts/build.py` to regenerate the schemes
and illustrated previews. Brand changes require review of both appearances.
Regenerate icon SVGs with `python3 scripts/build-icons.py`; optional PNG export
uses `python3 scripts/export-icons.py` with PyMuPDF in the contributor environment.
Committed PNGs require no renderer to use or verify.

CI checks source consistency, brand colors, icon hashes and native installation
under Windows PowerShell 5.1 and PowerShell 7. See the [validation record](VALIDATION.md),
[changelog](CHANGELOG.md) and [contribution guide](CONTRIBUTING.md).

</details>

## Support and license

[Open an issue](https://github.com/bacumi-tech/bacumi-windows-terminal-theme/issues)
with your Terminal version, selected appearance and a non-sensitive example.

Theme definitions, palette, code, documentation and original product icons are
covered by the [MIT License](LICENSE). Bacumi names identify this project;
trademark rights and endorsement of forks are not granted. The themes make no
runtime network requests and collect no telemetry.

Built using Microsoft's [color scheme](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/color-schemes)
and [JSON fragment](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions)
interfaces.
