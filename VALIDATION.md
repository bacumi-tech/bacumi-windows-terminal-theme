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

## Brand review — 0.1.1

Both Dark/Light palettes match the approved Bacumi editor adaptation exactly,
including all 16 ANSI colors. Master icon colors are the six exact Bacumi Brand
v1.0 values. The icons use original product-specific geometry, with no company
mark, third-party product logo, font or embedded image. Flat Graphite is the
approved small-format treatment; Light uses Off-White and Beige with contrast
edges. SVGs and PNGs were visually inspected at 256 px and in a small-size sheet.

CI validates the approved palette snapshot, exact master colors, generated SVG
consistency, PNG dimensions and source/export hashes. The brand checks require
only Python's standard library. Artwork export is an optional contributor step.
The existing native Windows Terminal/WSL visual-review limits still apply.

## Native developer prompt and optional font — 0.2.0 preview

Local PowerShell 7.6.7/macOS tests cover shared semantic Git fixtures and actual
Git states/operations, previous success/failure and native exit-code handling,
working-directory preservation, enable/disable/restore and repeated activation,
40-column widths, Unicode/control escaping, Dark/Light roles, plain/ANSI/truecolor
and opt-in icons. Native Windows CI runs prompt and ownership-safe installer
suites on both Windows PowerShell 5.1 and PowerShell 7.

The optional font tests use four controlled source fixtures and temporary
directories; Windows uses a unique test HKCU registration key. Tests include
WhatIf, partial/corrupt downloads, invalid manifests, failed mutation rollback,
repeat/update/removal, existing matching/conflicting fonts, local edits and
registry ownership. The official immutable font files were checked against the
committed hashes during development. No font binaries ship in the release ZIP.
The native font installer requires sign-out/sign-in to refresh availability
across apps; it does not edit Terminal profiles or automatically enable icons.

`python3 scripts/check-package.py` verifies the archive checksum, extracts the
actual release ZIP, installs/imports/enables/disables the module from a temporary
module directory and removes only installer-owned files.

These checks do not replace Windows Terminal GUI/WSL rendering acceptance.
Both native prompts remain previews pending that visual/font review.

### Performance sample

`scripts/benchmark-prompt.ps1 -Samples 30` was run on macOS 27.0.1 ARM64
(10 logical CPUs), official PowerShell 7.6.7, local temporary storage. Cold timing
includes a new PowerShell process, module import and first non-Git prompt.
The large case uses 3,000 tracked, 100 modified and 100 untracked files.

| Case | Median ms | 95th percentile ms |
| --- | ---: | ---: |
| Cold process + import + first prompt | 471.51 | 493.52 |
| Warm non-Git prompt | 16.30 | 21.79 |
| Large Git, Full | 144.04 | 186.48 |
| Large Git, Fast | 139.46 | 142.44 |

Results are diagnostic, not cross-platform performance promises. Windows CI
prints separate PowerShell 5.1 and 7 samples. Git checks use one local porcelain
status query per prompt; `-GitMode Fast` suppresses expensive detailed scanning,
and `-GitMode Off` skips Git. Runtime version probes have bounded caching.

## 0.3.0 preview — 2026-10-18

The original automated suite missed a controlling-terminal bug: Zsh `read -k`
read from `/dev/tty` despite file redirection. The regression now uses
`pty.fork()` (not only openpty/Popen), actual installed themes and real Oh My Zsh.
Small version files, empty/non-newline files, typed commands after `cd`, plugin
loading, status, resizing, Unicode/multiline input and Ctrl-C are exercised.

Native external probes now share an approximately 180 ms subprocess budget per
prompt, with EOF input, bounded output, timeout cleanup and short failure caching.
A Git status failure keeps bounded local HEAD information with explicit `status:?`;
partial/stale counts are suppressed. The budget does not bound filesystem or OS
scheduling calls. Deliberately daemonizing executable wrappers are outside the
ordinary-runtime fixtures; no arbitrary-process containment guarantee is made.

Real renderer fixtures cover Dark/Light, developer/compact, 40/80/120 columns,
plain/ANSI/truecolor and icons, including conflict/failure/unknown-state priority.
Developer SVGs now rerender from the actual native formatting code on controlled
data; they remain distinct from native emulator screenshots. ANSI fallback uses
readable inverse colors against the terminal's current background. Exact Bacumi
RGB colors require truecolor support.

Local macOS checks passed for native Zsh and PowerShell 7.6.7, including the
existing installer/font suites and archive installation. Hosted macOS/Linux and
Windows PowerShell 5.1/7 checks also passed:

- [Zsh macOS/Linux validation](https://github.com/bacumi-tech/bacumi-oh-my-zsh-theme/actions/runs/39140787999)
- [Windows PowerShell 5.1/7 validation](https://github.com/bacumi-tech/bacumi-windows-terminal-theme/actions/runs/39140424302)

Native Apple Terminal/iTerm2/Windows Terminal visual acceptance remains manual.
Version 0.3.0 remains a preview pending that acceptance.

PowerShell uses an in-process .NET helper compiled at module import to drain
bounded streams and own native processes, without an external prompt engine or
installed compiler dependency. Windows `.cmd` paths and Job Object cleanup passed
the actual Windows checks; Unix ordinary child cleanup was tested on Mac.
The formatter matrix contains 288 renders; process regressions include slow/hung
tools, input reads, stdout/stderr limits, failures, literal executable paths,
shared budget, unavailable-HEAD fallback and failure-cache recovery.

## Startup and Windows Git budgets — 2026-10-19

The native helper's existing C# code now lives in `prompt/NativeProbe.cs`.
The installer compiles it in a fresh, profile-free process for the current .NET
major, before replacing the existing installation. Installed imports load the
assembly bytes without invoking the compiler or locking the file on Windows.
Source checkouts and a different .NET major keep the standalone source fallback;
rerun the installer in the PowerShell edition you use to prepare its helper.

Tests cover fresh installed imports with runtime compilation forbidden, a real
Git probe, exclusive access to the loaded DLL, legacy two-file receipts, obsolete
helper removal, compiler failure before mutation, local source/DLL edits and
literal installation paths. Generated binaries are installer-owned and tracked
by the existing receipt; the release ZIP carries source rather than binaries.

A reported Windows Git query took 488.2611 ms, exceeding the old shared 180 ms
budget. Git now has a 750 ms limit and a 256 KiB output cap. Runtime-version checks
retain a separate shared 180 ms budget after Git, so a valid slower Git query
does not prevent runtime discovery. Full mode skips nested submodule working-tree
scans but retains tracked submodule commit changes. Tests include valid Git
queries beyond 180 ms, valid status output beyond 64 KiB, hung commands and
process cleanup. Worst-case subprocess budgets total approximately 930 ms;
filesystem, command discovery and OS scheduling remain outside those bounds.

The benchmark now installs into a temporary module directory and measures the
installed path, with import/activation/first-prompt phases. Local macOS ARM64
PowerShell 7.6.7 diagnostics observed a five-sample median of 448.16 ms for a
fresh process through its first prompt, including a 140.64 ms module import.
Before the change, three repository samples took 861–885 ms, with 406–415 ms
spent compiling at import. These are local diagnostic samples, not proof of the
reported 11,089 ms Windows profile load or a Windows performance guarantee.
