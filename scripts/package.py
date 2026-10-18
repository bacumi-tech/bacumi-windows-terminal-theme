"""Create a dependency-free installation ZIP with a SHA-256 checksum."""
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NAME = 'bacumi-windows-terminal-theme'
VERSION = (ROOT / "VERSION").read_text().strip()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", VERSION):
    raise SystemExit("VERSION must be major.minor.patch")
files = ["Install.ps1", "fragments/bacumi.json", "schemes/bacumi-dark.json", "schemes/bacumi-light.json"]
files += ["LICENSE", "README.md", "CONTRIBUTING.md", "VERSION", "CHANGELOG.md", "VALIDATION.md", "palette.json", "assets/bacumi-dark.svg", "assets/bacumi-light.svg"]
out = ROOT / "out"
out.mkdir(exist_ok=True)
archive = out / f"{NAME}-{VERSION}.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
    for relative in sorted(files):
        info = zipfile.ZipInfo(f"{NAME}-{VERSION}/{relative}", date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        package.writestr(info, (ROOT / relative).read_bytes())
with zipfile.ZipFile(archive) as package:
    assert package.testzip() is None
    assert len(package.namelist()) == len(files)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(out / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
print(f"Packaged {archive.name}: {len(files)} files, SHA-256 {digest}")
