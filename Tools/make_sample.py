#!/usr/bin/env python3
"""Generate a genuine parametric STEP bracket and the exact-revision preview."""
from pathlib import Path
import build123d as bd
from export_step import export_document, write_document


def main():
    root = Path(__file__).resolve().parent.parent
    destination = root / "Resources" / "precision-bracket.step"
    # Units mm: a mounting bracket, two base bores, and a upright through bore.
    base = bd.Box(84, 54, 8, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    upright = bd.Pos(0, 23, 8) * bd.Box(84, 8, 44,
                                      align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    bracket = base + upright
    for x in (-27, 27):
        bracket -= bd.Pos(x, -8, -1) * bd.Cylinder(5, 10,
                                                 align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    bracket -= bd.Pos(0, 23, 31) * bd.Rot(90, 0, 0) * bd.Cylinder(12, 12)
    bracket.label = "Mounting bracket"
    destination.parent.mkdir(parents=True, exist_ok=True)
    bd.export_step(bracket, destination, timestamp="2026-01-01T00:00:00")
    result = export_document(destination)
    write_document(result, destination.with_suffix(".cad.json"))
    print({"step": str(destination), "revision": result["revision"],
           "faces": len(result["faces"]), "edges": len(result["edges"]),
           "vertices": len(result["vertices"]), "triangles": sum(len(f["indices"]) // 3 for f in result["faces"])})


if __name__ == "__main__":
    main()
