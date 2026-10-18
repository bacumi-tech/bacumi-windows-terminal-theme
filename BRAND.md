# Bacumi brand alignment

Reviewed against Bacumi Brand v1.0 on 18 October 2026.

## Theme colors

The installed colors are the approved Bacumi editor adaptation, shared by the
Windows Terminal and Oh My Zsh projects as `bacumi-terminal-1`. Dark uses a
Graphite-derived `#17191F` reading surface; Light uses exact Off-White `#FAFAF8`.
Amber `#FFB347` supplies Dark focus, and the accessible Orange derivative
`#A34100` supplies Light focus. Sage, blue and muted terminal colors preserve
meaning and reading contrast. Semantic derivatives are intentional; the
master-logo Orange is not substituted into small text that needs darker ink.

The brand review confirmed both public palette files are identical and each
role matches the approved editor palette. `brand.json` pins the reviewed
palette snapshot so later changes require an explicit review. Each repository
can build and verify alone; no private brand repository is a dependency.

## Windows Terminal icon

A terminal window with an Orange command chevron, Amber cursor and a quiet title bar.

Original geometric product artwork uses the shared rounded field, generous safe
space and Orange/Amber accent hierarchy. The Dark field is flat Graphite; the
Light field is Off-White with a Beige edge. Small details and lettering are
omitted. Light-specific outlines preserve the symbol's contrast.

| Master token | Exact value |
| --- | --- |
| Graphite | `#0F1115` |
| Charcoal | `#1E2127` |
| Orange | `#FF6A00` |
| Amber | `#FFB347` |
| Beige | `#F3E7D6` |
| Off-White | `#FAFAF8` |

The SVG masters and PNG exports belong to this product and are included under
the repository's MIT license. They are not redrawings of the company's folded
ribbon mark or the Windows/Oh My Zsh logos. The company logo masters, brand kit
and font files are not bundled, and no trademark endorsement is implied.

## Files and reproduction

- `assets/icons/icon-dark.svg` and `icon-light.svg`: editable 1024-unit masters.
- `assets/icons/icon-{dark,light}-{16,32,128,256,512,1024}.png`: transparent exports.
- `assets/icons/provenance.json`: renderer and source/export SHA-256 hashes.
- `scripts/build-icons.py`: standalone SVG generation from `brand.json`.
- `scripts/export-icons.py`: optional PyMuPDF raster export; no font dependency.
- `scripts/check-brand.py`: standard-library palette and artwork checks for CI.

The icon is distributed for documentation, shortcuts and product listings.
The installer does not change the application's icon or existing user settings.
