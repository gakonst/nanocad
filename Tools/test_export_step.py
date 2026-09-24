"""Geometry-backed checks for the native renderer contract."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import build123d as bd
from cadgen import read_scene
from export_step import export_document, validate_document

ROOT = Path(__file__).resolve().parent.parent


def triples(values):
    return [values[i:i + 3] for i in range(0, len(values), 3)]


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sample = ROOT / "Resources/precision-bracket.step"
        cls.document = export_document(cls.sample)

    def test_saved_revision_and_every_native_reference(self):
        d = self.document
        self.assertEqual(d["revision"], hashlib.sha256(self.sample.read_bytes()).hexdigest())
        scene = read_scene(self.sample)
        self.assertEqual(d["revision"], scene.document_hash)
        self.assertEqual(d["name"], "precision-bracket.step")
        self.assertTrue(all(not e["id"].startswith("#") for key in ("faces", "edges", "vertices", "parts") for e in d[key]))
        for face in d["faces"]:
            self.assertAlmostEqual(scene.resolve(face["id"]).shape().area, face["area"], places=7)
        for edge in d["edges"]:
            self.assertAlmostEqual(scene.resolve(edge["id"]).shape().length, edge["length"], places=7)
        for vertex in d["vertices"]:
            self.assertEqual(list(scene.resolve(vertex["id"]).shape()), vertex["position"])
        expected = {s.ref.removeprefix("#") for o in scene.leaves() for s in o.entities("face")}
        self.assertEqual(expected, {f["id"] for f in d["faces"]})

    def test_winding_unit_normals_and_positive_solid_volume(self):
        validate_document(self.document)
        volume = 0.0
        for face in self.document["faces"]:
            points, normals = triples(face["positions"]), triples(face["normals"])
            for normal in normals:
                self.assertAlmostEqual(sum(x * x for x in normal), 1, places=5)
            for ia, ib, ic in triples(face["indices"]):
                a, b, c = points[ia], points[ib], points[ic]
                u = [b[i] - a[i] for i in range(3)]
                v = [c[i] - a[i] for i in range(3)]
                cross = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
                norm = sum(x*x for x in cross) ** 0.5
                if norm > 1e-10:
                    avg = [sum(normals[j][i] for j in (ia, ib, ic)) / 3 for i in range(3)]
                    self.assertGreater(sum(cross[i]*avg[i] for i in range(3)) / norm, 0.8, face["id"])
                volume += (a[0]*(b[1]*c[2]-b[2]*c[1]) + a[1]*(b[2]*c[0]-b[0]*c[2]) + a[2]*(b[0]*c[1]-b[1]*c[0])) / 6
        exact = sum(s.shape().volume for o in read_scene(self.sample).leaves() for s in o.entities("shape"))
        self.assertGreater(volume, 0)
        self.assertLess(abs(volume - exact) / exact, 0.01)

    def test_repeated_instances_keep_world_placement_and_distinct_refs(self):
        with tempfile.TemporaryDirectory(prefix="cad-export-", dir=ROOT / "evidence") as directory:
            shape = bd.Box(8, 10, 12)
            a = shape.moved(bd.Location((-20, 0, 0)))
            b = shape.moved(bd.Location((20, 4, 6), (0, 0, 90)))
            a.label, b.label = "left", "right"
            assembly = bd.Compound(children=[a, b], label="repeated")
            path = Path(directory) / "assembly.step"
            bd.export_step(assembly, path)
            d = export_document(path)
            self.assertEqual(len(d["parts"]), 2)
            face_by_id = {face["id"]: face for face in d["faces"]}
            centers = []
            for part in d["parts"]:
                points = [p for fid in part["faceIDs"] for p in triples(face_by_id[fid]["positions"])]
                centers.append(tuple(round((min(p[i] for p in points)+max(p[i] for p in points))/2, 5) for i in range(3)))
            self.assertEqual(set(centers), {(-20, 0, 0), (20, 4, 6)})
            self.assertEqual(len(d["faces"]), 12)
            self.assertEqual(len({f["id"] for f in d["faces"]}), 12)

    def test_sphere_degenerate_edges_remain_valid_native_refs(self):
        with tempfile.TemporaryDirectory(prefix="cad-poles-", dir=ROOT / "evidence") as directory:
            path = Path(directory) / "sphere.step"
            bd.export_step(bd.Sphere(10), path)
            document = export_document(path)
            validate_document(document)
            scene = read_scene(path)
            expected = {e.ref.removeprefix("#") for o in scene.leaves() for e in o.entities("edge")}
            self.assertEqual(expected, {e["id"] for e in document["edges"]})
            self.assertTrue(all(len(e["points"]) >= 6 for e in document["edges"]))

    def test_warm_export_is_identical_and_matches_bundled_preview(self):
        self.assertEqual(self.document, export_document(self.sample))
        self.assertEqual(self.document, json.loads(self.sample.with_suffix(".cad.json").read_text()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
