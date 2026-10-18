# Validation and compatibility

## Automated checks

- Both generated schemes and the fragment consumed by Windows Terminal have the
  required 16 ANSI colors, foreground/background, cursor and selection colors.
- Every ANSI foreground and the main foreground meet 4.5:1 against the default
  background. The main foreground meets 4.5:1 on the selection background;
  the cursor meets 3:1 on the default background. Application-defined colors and
  all possible selected foregrounds are outside these guarantees.
- The installer suite uses temporary paths to exercise installation, repeat
  installation, uninstall, `-WhatIf`, local-edit protection and unrelated-file
  preservation. CI runs it on actual Windows under Windows PowerShell 5.1 and
  PowerShell 7. It does not launch the Terminal GUI.
- Local development on 18 October 2026 used Python 3.13 and a temporary official
  PowerShell 7.6.7 runtime on macOS. No user Terminal settings were changed.

## Native visual review before a stable release

The initial release is a **preview**. Actual Windows Terminal GUI review has not
been performed on the development Mac. Before calling the release stable:

- Install from the release ZIP on Windows and record the Terminal version.
- Confirm both schemes appear and apply to PowerShell, cmd and WSL profiles.
- Review ANSI swatches, Git differences, error output, cursor and selections.
- Inspect both variants at default opacity and typical font sizes. Applications
  may supply colors of their own; do not claim universal contrast.
- Confirm update/uninstall and unchanged existing profiles on that machine.
- Replace or supplement the illustrated previews with clearly identified native
  screenshots, keeping the distinction accurate.

No npm, pip, Microsoft Store or VS Code Marketplace package is published.
