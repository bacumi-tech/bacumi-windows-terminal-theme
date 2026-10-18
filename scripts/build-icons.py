"""Generate original MIT product icons using the public Bacumi brand subset."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def icons():
    brand = json.loads((ROOT / "brand.json").read_text())
    p = brand["master"]
    files = {}
    for mode in ("dark", "light"):
        field = p["graphite"] if mode == "dark" else p["off_white"]
        ink = p["off_white"] if mode == "dark" else p["graphite"]
        edge = p["charcoal"] if mode == "dark" else p["beige"]
        title = f'Bacumi {brand["product"]} — {mode.title()} product icon'
        svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title description">
  <title id="title">{title}</title>
  <desc id="description">A terminal window with an Orange command prompt and an Amber cursor, on a rounded Bacumi field.</desc>
  <rect x="32" y="32" width="960" height="960" rx="220" fill="{field}"/>
  <rect x="54" y="54" width="916" height="916" rx="198" fill="none" stroke="{edge}" stroke-width="8"/>
  <rect x="192" y="240" width="640" height="544" rx="64" fill="{p['graphite']}" stroke="{ink}" stroke-width="32"/>
  <path d="M208 364H816" fill="none" stroke="{p['off_white']}" stroke-width="24"/>
  <rect x="264" y="292" width="104" height="24" rx="12" fill="{p['orange']}"/>
  <path d="M306 456L418 560L306 664" fill="none" stroke="{p['orange']}" stroke-width="60" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M504 660H692" fill="none" stroke="{p['amber']}" stroke-width="60" stroke-linecap="round"/>
</svg>
'''
        files[f"assets/icons/icon-{mode}.svg"] = svg
    return files


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name, content in icons().items():
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                raise SystemExit(f"Rebuild required: {name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    print("Bacumi product icon masters verified." if args.check else "Built Dark and Light product icons.")
