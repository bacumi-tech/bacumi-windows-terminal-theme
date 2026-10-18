"""Verify the approved palette snapshot and committed product icon exports."""
import hashlib
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
brand = json.loads((ROOT / "brand.json").read_text())
palette_file = ROOT / "palette.json"
assert hashlib.sha256(palette_file.read_bytes()).hexdigest() == brand["paletteSha256"], "Palette changed: review Dark/Light against the brand before updating the approved snapshot"
assert json.loads(palette_file.read_text())["revision"] == brand["paletteRevision"]
master = brand["master"]
assert master == {"graphite": "#0F1115", "charcoal": "#1E2127", "orange": "#FF6A00", "amber": "#FFB347", "beige": "#F3E7D6", "off_white": "#FAFAF8"}, "Master brand colors must remain exact"
folder = ROOT / "assets/icons"
provenance = json.loads((folder / "provenance.json").read_text())
expected = {f"icon-{mode}.svg" for mode in ("dark", "light")}
expected |= {f"icon-{mode}-{size}.png" for mode in ("dark", "light") for size in (16, 32, 128, 256, 512, 1024)}
assert set(provenance["files"]) == expected
for name, digest in provenance["files"].items():
    data = (folder / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest, f"Stale icon export: {name}"
    if name.endswith(".png"):
        size = int(name.removesuffix(".png").rsplit("-", 1)[1])
        assert data.startswith(b"\x89PNG\r\n\x1a\n")
        assert struct.unpack(">II", data[16:24]) == (size, size), name
    else:
        svg = ET.fromstring(data)
        assert svg.attrib["viewBox"] == "0 0 1024 1024"
        for element in svg.iter():
            assert element.tag.rsplit("}", 1)[-1] not in {"text", "image", "script", "foreignObject"}, "Icon must use self-contained geometric artwork without fonts or embedded content"
            for attribute in ("fill", "stroke", "stop-color"):
                value = element.get(attribute)
                if value:
                    assert value == "none" or value in master.values(), f"Unapproved icon color: {value}"
print("Bacumi Brand v1.0 colors, approved terminal palette, two icon masters and 12 PNG exports verified.")
