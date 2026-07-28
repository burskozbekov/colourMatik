"""The Windows panel disappears if the manifest asks for a permission Premiere
refuses. Every build after 1.2.0 declared ".exe" under launchProcess and was
silently never listed under Window > UXP Plugins - with correct files and a
correct registry entry, so nothing looked wrong anywhere else. Lock the shape
that is proven to load."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_launchprocess_has_no_exe():
    mf = json.loads((ROOT / "colourmatik-uxp" / "manifest.json").read_text())
    ext = mf["requiredPermissions"]["launchProcess"]["extensions"]
    assert ".exe" not in ext, (
        "Premiere on Windows refuses this manifest and the panel never appears. "
        f"extensions={ext}")
    assert ext == [".app", ""], f"unexpected extensions {ext}"


def test_versions_agree():
    mf = json.loads((ROOT / "colourmatik-uxp" / "manifest.json").read_text())
    vj = json.loads((ROOT / "version.json").read_text())
    panel = (ROOT / "colourmatik-uxp" / "main.js").read_text()
    assert f'LOCAL_VERSION = "{mf["version"]}"' in panel
    assert vj["version"] == mf["version"]
