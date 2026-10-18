"""Optional raster export: requires PyMuPDF only when refreshing icon artwork."""
import hashlib
import json
from pathlib import Path
import struct

try:
    import fitz
except ImportError:
    raise SystemExit("PNG export requires PyMuPDF. Committed SVG/PNG assets need no renderer to install or verify.")

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / "assets/icons"
record = {"source": "Original Bacumi product SVGs; deterministic vector geometry, not the company mark.",
          "license": "MIT", "renderer": f"PyMuPDF {fitz.VersionBind}", "files": {}}
for mode in ("dark", "light"):
    source = folder / f"icon-{mode}.svg"
    record["files"][source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
    with fitz.open(stream=source.read_bytes(), filetype="svg") as document:
        for size in (16, 32, 128, 256, 512, 1024):
            path = folder / f"icon-{mode}-{size}.png"
            document[0].get_pixmap(matrix=fitz.Matrix(size / 1024, size / 1024), alpha=True).save(str(path))
            data = path.read_bytes()
            assert struct.unpack(">II", data[16:24]) == (size, size)
            record["files"][path.name] = hashlib.sha256(data).hexdigest()
(folder / "provenance.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
print("Exported Dark/Light PNGs at 16, 32, 128, 256, 512 and 1024 px with source hashes.")
