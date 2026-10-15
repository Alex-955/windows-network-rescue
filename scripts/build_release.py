"""Build a portable, allowlisted Windows toolkit ZIP. Does not publish anything."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.2.0"
FILES = (
    "NetRescue.ps1", "ReportCleanup.ps1", "CLEAN-REPORTS.cmd", "CHECK-ONLY.cmd", "PREVIEW.cmd", "START.cmd", "AUTO-FIX.cmd",
    "使用说明.txt", "使用指南.html",
)
output = ROOT / "dist"
output.mkdir(exist_ok=True)
archive = output / f"Windows-Net-Rescue-v{VERSION}.zip"
expected = {}
for name in FILES:
    path = ROOT / "Windows-Net-Rescue" / name
    data = path.read_bytes()
    if path.suffix in (".ps1", ".txt"):
        assert data.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM required: {name}"
    if path.suffix in (".ps1", ".cmd", ".txt"):
        assert b"\n" not in data.replace(b"\r\n", b""), f"CRLF required: {name}"
    if path.suffix == ".cmd":
        data.decode("ascii")
    expected[f"Windows-Net-Rescue/{name}"] = data
expected["Windows-Net-Rescue/LICENSE"] = (ROOT / "LICENSE").read_bytes()
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
    for name, data in expected.items():
        bundle.writestr(name, data)
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None
    assert set(bundle.namelist()) == set(expected)
    for name, data in expected.items():
        assert bundle.read(name) == data, f"ZIP readback mismatch: {name}"
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
print(f"Built and verified {archive.name}: {len(expected)} files")
print(f"SHA256: {digest}")
