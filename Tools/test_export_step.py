"""Geometry-backed checks for the native renderer contract."""
import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest

import build123d as bd
from cadgen import read_scene
from export_step import export_document, validate_document, write_checkpoint

ROOT = Path(__file__).resolve().parent.parent
# Exact STEP metrics tolerate kernel floating-point roundoff. Sampled geometry
# uses the exporter's default absolute deflection, in document millimeters.
METRIC_TOLERANCE = 1e-7
DEFLECTION_MM = 0.08


def triples(values):
    return [values[i:i + 3] for i in range(0, len(values), 3)]


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sample = ROOT / "Resources/precision-bracket.step"
        cls.scene = read_scene(cls.sample)
        cls.document = export_document(cls.sample)
        cls.bundled = json.loads(cls.sample.with_suffix(".cad.json").read_text())

    def test_checkpoint_publishes_coherent_pair_and_preserves_last_good_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_checkpoint(self.sample, self.document, root, 1)
            original = (root / "latest.json").read_bytes()
            manifest = json.loads(original)
            for file in manifest["files"]:
                data = (root / file["path"]).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), file["sha256"])
                self.assertEqual(len(data), file["size"])
            preview = json.loads((root / "r1/model.cad.json").read_text())
            self.assertEqual(preview["name"], "model.step")
            self.assertEqual(preview["revision"], hashlib.sha256((root / "r1/model.step").read_bytes()).hexdigest())
            changed_step = root / "changed.step"
            changed_step.write_bytes(self.sample.read_bytes() + b"\n")
            with self.assertRaises(ValueError):
                write_checkpoint(changed_step, self.document, root, 2)
            self.assertEqual((root / "latest.json").read_bytes(), original)
            write_checkpoint(self.sample, self.document, root, 2)
            with self.assertRaises(ValueError):
                write_checkpoint(self.sample, self.document, root, 1)
            self.assertEqual(json.loads((root / "latest.json").read_text())["revision"], 2)

    def assert_sampled_bounds(self, points, shape, reference):
        bounds = shape.bounding_box()
        for expected, extrema in ((bounds.min, min), (bounds.max, max)):
            for axis, value in enumerate(expected):
                self.assertAlmostEqual(
                    extrema(point[axis] for point in points), value,
                    delta=DEFLECTION_MM + METRIC_TOLERANCE, msg=reference)

    def assert_saved_geometry(self, document):
        validate_document(document)
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["units"], "mm")
        self.assertEqual(document["name"], self.sample.name)
        self.assertEqual(document["revision"], hashlib.sha256(self.sample.read_bytes()).hexdigest())
        self.assertEqual(document["revision"], self.scene.document_hash)
        occurrences = list(self.scene.leaves())
        for kind, key in (("face", "faces"), ("edge", "edges"), ("vertex", "vertices")):
            expected = {s.ref.removeprefix("#") for o in occurrences for s in o.entities(kind)}
            self.assertEqual(expected, {entity["id"] for entity in document[key]}, key)
        self.assertEqual({o.ref.removeprefix("#") for o in occurrences},
                         {part["id"] for part in document["parts"]})
        parts = {part["id"]: part for part in document["parts"]}
        for occurrence in occurrences:
            part = parts[occurrence.ref.removeprefix("#")]
            expected = [f.ref.removeprefix("#") for f in occurrence.entities("face")]
            self.assertCountEqual(part["faceIDs"], expected)
            self.assertEqual(part["name"], occurrence.label or occurrence.ref)
        for face in document["faces"]:
            shape = self.scene.resolve(face["id"]).shape()
            self.assertAlmostEqual(face["area"], shape.area, delta=METRIC_TOLERANCE, msg=face["id"])
            self.assert_sampled_bounds(triples(face["positions"]), shape, face["id"])
        for edge in document["edges"]:
            shape = self.scene.resolve(edge["id"]).shape()
            self.assertAlmostEqual(edge["length"], shape.length, delta=METRIC_TOLERANCE, msg=edge["id"])
            points = triples(edge["points"])
            self.assert_sampled_bounds(points, shape, edge["id"])
            sampled_length = sum(math.dist(a, b) for a, b in zip(points, points[1:]))
            self.assertAlmostEqual(sampled_length, shape.length,
                                   delta=shape.length * 0.01 + METRIC_TOLERANCE, msg=edge["id"])
        for vertex in document["vertices"]:
            self.assertEqual(len(vertex["position"]), 3)
            for actual, expected in zip(vertex["position"], self.scene.resolve(vertex["id"]).shape()):
                self.assertAlmostEqual(actual, expected, delta=METRIC_TOLERANCE, msg=vertex["id"])

    def test_saved_revision_and_every_native_reference(self):
        self.assert_saved_geometry(self.document)

    def test_bundled_preview_matches_saved_geometry(self):
        # OCCT can choose different triangle/node order across platforms. Resolve
        # canonical topology and compare true STEP metrics, not those buffers.
        self.assert_saved_geometry(self.bundled)

    def test_winding_unit_normals_and_positive_solid_volume(self):
        exact_volume = sum(s.shape().volume for o in self.scene.leaves() for s in o.entities("shape"))
        for source, document in (("exported", self.document), ("bundled", self.bundled)):
            with self.subTest(source=source):
                validate_document(document)
                volume = 0.0
                for face in document["faces"]:
                    points, normals = triples(face["positions"]), triples(face["normals"])
                    area = 0.0
                    for normal in normals:
                        self.assertAlmostEqual(sum(x * x for x in normal), 1, places=5, msg=face["id"])
                    for ia, ib, ic in triples(face["indices"]):
                        a, b, c = points[ia], points[ib], points[ic]
                        u = [b[i] - a[i] for i in range(3)]
                        v = [c[i] - a[i] for i in range(3)]
                        cross = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
                        norm = sum(x*x for x in cross) ** 0.5
                        area += norm / 2
                        if norm > 1e-10:
                            avg = [sum(normals[j][i] for j in (ia, ib, ic)) / 3 for i in range(3)]
                            self.assertGreater(sum(cross[i]*avg[i] for i in range(3)) / norm, 0.8, face["id"])
                        volume += (a[0]*(b[1]*c[2]-b[2]*c[1]) + a[1]*(b[2]*c[0]-b[0]*c[2]) + a[2]*(b[0]*c[1]-b[1]*c[0])) / 6
                    exact_area = self.scene.resolve(face["id"]).shape().area
                    self.assertAlmostEqual(area, exact_area,
                                           delta=exact_area * 0.01 + METRIC_TOLERANCE, msg=face["id"])
                self.assertGreater(volume, 0)
                self.assertLess(abs(volume - exact_volume) / exact_volume, 0.01)

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

    def test_warm_export_is_identical_on_the_same_runtime(self):
        self.assertEqual(self.document, export_document(self.sample))


if __name__ == "__main__":
    unittest.main(verbosity=2)
