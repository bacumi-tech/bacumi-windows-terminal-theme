# Bacumi for Windows Terminal

Two warm, readable color schemes: **Bacumi Dark** and **Bacumi Light**.
Graphite and Off-White backgrounds, Amber focus, sage greens and quiet blues.
Free and open source under the [MIT License](LICENSE).

![Bacumi Dark illustrated palette](assets/bacumi-dark.svg)
![Bacumi Light illustrated palette](assets/bacumi-light.svg)

These are illustrated palette previews, not Windows Terminal screenshots.
The schemes change colors only; fonts, keybindings and profile commands stay yours.

## Install from GitHub Releases

1. Download `bacumi-windows-terminal-theme-0.1.0.zip` from
   [Releases](https://github.com/bacumi-tech/bacumi-windows-terminal-theme/releases).
2. Extract the ZIP. Open PowerShell in the extracted directory and run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

3. Reopen Windows Terminal. Open **Settings → your profile → Appearance → Color
   scheme**, choose **Bacumi Dark** or **Bacumi Light**, and save.

The execution-policy option applies only to that installer process. The script
works with Windows PowerShell 5.1 and PowerShell 7; it requires no administrator
rights, Git, Node.js or Python. Terminal must support JSON fragment extensions.

Both variants are installed as one native fragment in
`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Bacumi\bacumi.json`.
The installer never rewrites `settings.json` or changes your selected scheme.
For automatic Dark/Light selection on compatible Terminal versions, set your
profile's `colorScheme` to `{ "dark": "Bacumi Dark", "light": "Bacumi Light" }`.

## Manual installation

Copy `fragments/bacumi.json` into a `Bacumi` folder under the fragment location
above. Alternatively, copy the objects from `schemes/bacumi-dark.json` and
`schemes/bacumi-light.json` into the `schemes` array of your Terminal settings.
Then select the scheme in your profile. Manual copies are managed manually;
the installer refuses to overwrite a folder it does not own.

## Update and uninstall

Download and extract a newer release, then run the installer again. It updates
only its own fragment. If you edited that fragment, the script stops so you can
back up or move your custom version first. Keep personal color overrides in your
Terminal settings or a separately named scheme.

To remove an installer-managed copy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
```

Choose another scheme if a profile still refers to Bacumi. Uninstall removes
only its fragment and ownership marker; unrelated files are preserved. A manual
installation can be removed by deleting the file you copied.

Preview changes with `-WhatIf`. Tests and custom installations can pass
`-FragmentRoot 'C:\path\to\Fragments'`; this is the **Fragments** directory,
not a Windows Terminal settings directory.

## Build and verify

End users need only the release ZIP. Contributors use a source checkout and
Python 3.10+ with no packages:

```sh
python3 scripts/build.py --check
python3 -m unittest discover -s tests -v
```

On Windows, also run the standalone installer tests:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\install.Tests.ps1
```

Edit `palette.json`, then run `python3 scripts/build.py` to regenerate schemes
and illustrated previews. CI checks generated output and tests installation in
temporary directories on Windows PowerShell 5.1 and PowerShell 7. Actual Terminal
GUI appearance still needs the [native review checklist](VALIDATION.md).

Palette revision `bacumi-terminal-1` matches the independently distributed
[Bacumi Oh My Zsh theme](https://github.com/bacumi-tech/bacumi-oh-my-zsh-theme).
Both repositories build alone. No runtime network calls or telemetry.

## Contribute and license

See [CONTRIBUTING.md](CONTRIBUTING.md). Report issues with your Terminal version,
scheme and a non-sensitive example. The MIT license covers this repository's
theme definitions, palette, code, documentation and illustrations. Bacumi names
identify this project; the license does not grant trademark rights or imply
endorsement of forks. No proprietary logos or fonts are bundled.

Implementation follows Microsoft's [color-scheme documentation](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/color-schemes)
and [JSON fragment extension documentation](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions).
