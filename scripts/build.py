"""Build distributable schemes and an explicitly illustrated preview; stdlib only."""
import argparse
from html import escape
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def outputs():
    variants = json.loads((ROOT / "palette.json").read_text())["variants"]
    files, schemes = {}, []
    for mode, p in variants.items():
        scheme = {"name": f"Bacumi {mode.title()}", "foreground": p["foreground"],
                  "background": p["background"], "cursorColor": p["cursor"],
                  "selectionBackground": p["selection"]}
        scheme.update({key.replace("Magenta", "Purple").replace("magenta", "purple"): value for key, value in p["ansi"].items()})
        schemes.append(scheme)
        files[f"schemes/bacumi-{mode}.json"] = json.dumps(scheme, indent=2) + "\n"
        rows = [f'<text x="40" y="42" fill="{p["foreground"]}" font-size="21">Bacumi {mode.title()} · Windows Terminal</text>',
                f'<text x="40" y="99" fill="{p["accent"]}">PS C:\\work\\bacumi&gt; git status</text>',
                f'<text x="40" y="135" fill="{p["ansi"]["green"]}">On branch main — working tree clean</text>',
                f'<text x="40" y="192" fill="{p["muted"]}">ANSI colors / normal and bright</text>']
        for i, (name, color) in enumerate(p["ansi"].items()):
            x, y = 40 + (i % 8) * 90, 225 + (i // 8) * 78
            rows.append(f'<rect x="{x}" y="{y}" width="68" height="16" rx="4" fill="{color}"/><text x="{x}" y="{y+40}" font-size="10" fill="{color}">{escape(name)}</text>')
        rows.append(f'<text x="40" y="415" font-size="12" fill="{p["muted"]}">Illustrated palette preview · not a native screenshot</text>')
        files[f"assets/bacumi-{mode}.svg"] = f'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="450" viewBox="0 0 800 450" role="img" aria-label="Bacumi {mode} illustrated terminal palette"><rect width="800" height="450" rx="16" fill="{p["background"]}"/><g font-family="ui-monospace, Consolas, monospace" font-size="17">' + "".join(rows) + '</g></svg>\n'
    files["fragments/bacumi.json"] = json.dumps({"schemes": schemes}, indent=2) + "\n"
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name, content in outputs().items():
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                raise SystemExit(f"Rebuild required: {name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    print("Bacumi Dark/Light schemes, native fragment and illustrated previews verified." if args.check else "Built Bacumi Dark/Light.")
