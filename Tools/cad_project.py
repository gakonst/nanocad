#!/usr/bin/env python3
"""Install NanoCAD's pinned CAD skill without importing the geometry kernel."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

REVISION = "4eaf7459a95c0547b089ab53aa579c7597fab1d5"


def install_skill(bundle: Path, destination: Path) -> dict:
    data = bundle.read_bytes()
    if len(data) > 600_000:
        raise ValueError("Skill bundle exceeds the upload bound")
    digest = hashlib.sha256(data).hexdigest()
    marker = destination / ".nanocad-skill.json"
    try:
        installed = json.loads(marker.read_text())
        if installed.get("bundle_sha256") == digest and (destination / "SKILL.md").is_file():
            return installed
    except (OSError, ValueError):
        pass
    package = json.loads(data)
    if package.get("revision") != REVISION or package.get("version") != "0.6.6" or package.get("schema") != 1:
        raise ValueError("Unexpected CAD skill revision")
    files = package.get("files", [])
    if not 1 <= len(files) <= 64:
        raise ValueError("Invalid CAD skill files")
    checked = []
    for item in files:
        name, content = item["path"], item["content"]
        path = PurePosixPath(name)
        if not name or path.is_absolute() or ".." in path.parts or "\\" in name or str(path) != name or not isinstance(content, str):
            raise ValueError("Unsafe skill path")
        target = destination / name
        if not target.resolve().is_relative_to(destination.resolve()):
            raise ValueError("Skill destination escapes its root")
        checked.append((target, content.encode()))
    for target, content in checked:
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != content:
            temporary = target.with_suffix(target.suffix + ".tmp")
            temporary.write_bytes(content)
            temporary.replace(target)
    receipt = {"skill": str(destination / "SKILL.md"), "version": package["version"], "revision": REVISION,
               "bundle_sha256": digest}
    temporary = marker.with_suffix(".tmp")
    temporary.write_text(json.dumps(receipt))
    temporary.replace(marker)
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--out", type=Path, default=Path("/brain/skills/cad"))
    args = parser.parse_args()
    print(json.dumps(install_skill(args.bundle, args.out)))
