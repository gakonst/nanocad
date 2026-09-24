#!/usr/bin/env python3
"""Export a saved STEP revision to NanoCAD's native mesh contract v1.

Install cadgen==0.6.6 in a Python 3.11+ environment. This reads saved STEP
geometry only; it never discovers or executes a neighboring model script.
Refs come from cadgen.read_scene, matching CAD Viewer's face/edge ordinals.
The mesh uses OCCT (not CAD Viewer's JavaScript tessellator).
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import tempfile

from cadgen import read_scene
from OCP.BRep import BRep_Tool
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.BRepLib import BRepLib_ToolTriangulatedShape
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepTools import BRepTools
from OCP.GCPnts import GCPnts_QuasiUniformDeflection
from OCP.TopAbs import TopAbs_REVERSED
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS


def xyz(point) -> list[float]:
    return [float(point.X()), float(point.Y()), float(point.Z())]


def face_mesh(selection, tolerance_mm: float, angle_radians: float) -> dict:
    owned = selection.shape()  # caller-owned native shape, WORLD coordinates
    face = TopoDS.Face_s(owned.wrapped)
    BRepTools.Clean_s(face)  # remove any cached coarser triangulation on this copy
    mesher = BRepMesh_IncrementalMesh(face, tolerance_mm, False, angle_radians, False)
    if not mesher.IsDone():
        raise RuntimeError(f"OCCT meshing failed: {selection.ref}")
    location = TopLoc_Location()
    triangulation = BRep_Tool.Triangulation_s(face, location)
    if triangulation is None or triangulation.NbTriangles() == 0:
        raise RuntimeError(f"No triangles for {selection.ref}")
    BRepLib_ToolTriangulatedShape.ComputeNormals_s(face, triangulation)
    transform = location.Transformation()
    reverse = face.Orientation() == TopAbs_REVERSED
    positions, normals, indices = [], [], []
    for ordinal in range(1, triangulation.NbNodes() + 1):
        positions.extend(xyz(triangulation.Node(ordinal).Transformed(transform)))
        normal = triangulation.Normal(ordinal).Transformed(transform)
        if reverse:
            normal.Reverse()
        normals.extend(xyz(normal))
    for ordinal in range(1, triangulation.NbTriangles() + 1):
        a, b, c = triangulation.Triangle(ordinal).Get()
        indices.extend([a - 1, c - 1, b - 1] if reverse else [a - 1, b - 1, c - 1])
    return {"id": selection.ref.removeprefix("#"), "positions": positions, "normals": normals,
            "indices": indices, "area": float(owned.area)}


def edge_line(selection, tolerance_mm: float) -> dict:
    owned = selection.shape()
    edge = TopoDS.Edge_s(owned.wrapped)
    if BRep_Tool.Degenerated_s(edge):
        # Pole/seam degeneracies remain selectable topology, but have no stroke.
        vertices = list(selection.entities("vertex"))
        if not vertices:
            raise RuntimeError(f"Degenerate edge has no vertex: {selection.ref}")
        points = list(vertices[0].shape()) * 2
    else:
        curve = BRepAdaptor_Curve(edge)
        samples = GCPnts_QuasiUniformDeflection(curve, tolerance_mm)
        if not samples.IsDone() or samples.NbPoints() < 2:
            raise RuntimeError(f"Curve sampling failed: {selection.ref}")
        points = [value for i in range(1, samples.NbPoints() + 1)
                  for value in xyz(samples.Value(i))]
    return {"id": selection.ref.removeprefix("#"), "points": points, "length": float(owned.length)}


def export_document(step_path: Path | str, *, tolerance_mm: float = 0.08,
                    angle_radians: float = 0.15) -> dict:
    for name, value in (("tolerance_mm", tolerance_mm), ("angle_radians", angle_radians)):
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"{name} must be finite and positive")
    path = Path(step_path).expanduser().resolve()
    scene = read_scene(path)
    faces, edges, vertices, parts = [], [], [], []
    for occurrence in scene.leaves():
        face_ids = []
        for selection in occurrence.entities("face"):
            faces.append(face_mesh(selection, tolerance_mm, angle_radians))
            face_ids.append(selection.ref.removeprefix("#"))
        edges.extend(edge_line(selection, tolerance_mm)
                     for selection in occurrence.entities("edge"))
        vertices.extend({"id": selection.ref.removeprefix("#"),
                         "position": list(selection.shape())}
                        for selection in occurrence.entities("vertex"))
        parts.append({"id": occurrence.ref.removeprefix("#"), "name": occurrence.label or occurrence.ref,
                      "faceIDs": face_ids})
    result = {"schemaVersion": 1, "name": path.name, "revision": scene.document_hash,
              "units": "mm", "faces": faces, "edges": edges,
              "vertices": vertices, "parts": parts}
    validate_document(result)
    return result


def validate_document(document: dict) -> None:
    """Check the consumer's index, geometry and identity invariants before write."""
    ids = [entity["id"] for key in ("faces", "edges", "vertices", "parts")
           for entity in document[key]]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate CAD references")
    for face in document["faces"]:
        positions, normals, indices = face["positions"], face["normals"], face["indices"]
        if not positions or len(positions) % 3 or len(normals) != len(positions):
            raise ValueError(f"Invalid packed vertex arrays: {face['id']}")
        if not indices or len(indices) % 3 or any(i < 0 or i >= len(positions) // 3 for i in indices):
            raise ValueError(f"Out-of-range triangle indices: {face['id']}")
    if not document["faces"]:
        raise ValueError("Native preview requires at least one surface face")
    for edge in document["edges"]:
        if len(edge["points"]) < 6 or len(edge["points"]) % 3:
            raise ValueError(f"Invalid packed edge points: {edge['id']}")
    face_ids = {face["id"] for face in document["faces"]}
    if any(ref not in face_ids for part in document["parts"] for ref in part["faceIDs"]):
        raise ValueError("Part references an unknown face")
    # JSON's normal permissive NaN/Infinity encoding is invalid for Swift JSONDecoder.
    json.dumps(document, allow_nan=False)


def write_document(document: dict, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    # Atomic publication: a watcher never sees a partial JSON file.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent,
                                     prefix=output.name + ".", suffix=".tmp", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(document, stream, separators=(",", ":"), allow_nan=False)
            stream.write("\n")
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    temporary.replace(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", type=Path)
    parser.add_argument("--out", type=Path, help="Default: INPUT basename with .cad.json suffix")
    parser.add_argument("--tolerance-mm", type=float, default=0.08)
    parser.add_argument("--angle-radians", type=float, default=0.15)
    args = parser.parse_args()
    result = export_document(args.step, tolerance_mm=args.tolerance_mm, angle_radians=args.angle_radians)
    output = args.out or args.step.with_suffix(".cad.json")
    write_document(result, output)
    print(json.dumps({"output": str(output.resolve()), "revision": result["revision"],
                      "faces": len(result["faces"]), "edges": len(result["edges"]),
                      "vertices": len(result["vertices"]), "parts": len(result["parts"]),
                      "triangles": sum(len(f["indices"]) // 3 for f in result["faces"])}))


if __name__ == "__main__":
    main()
