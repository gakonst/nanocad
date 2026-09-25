# Native CAD export

`Tools/export_step.py` reads a saved STEP/STP with `cadgen.read_scene` and writes contract v1 for `CADDocument.swift`. All positions are document world coordinates in millimeters. IDs are numeric CAD refs without a leading `#`; the UI forms `precision-bracket.step#o1.f1`. `revision` is SHA-256 of the exact STEP bytes. No neighboring Python source is executed.

```sh
uv venv --python 3.12 .cadgen-venv
uv pip install --python .cadgen-venv/bin/python -r Tools/requirements.txt
.cadgen-venv/bin/python Tools/export_step.py part.step --out part.cad.json
.cadgen-venv/bin/python Tools/make_sample.py
.cadgen-venv/bin/python Tools/test_export_step.py
```

The included genuine model is `Resources/precision-bracket.step` and its paired `Resources/precision-bracket.cad.json`. Dimensions: 84 × 54 × 52 mm; two Ø10 base bores and a Ø24 upright bore; 11 faces, 27 edges, 18 native vertices, 1,040 triangles. The independent mesh image is `evidence/precision-bracket-export.png`; it does not establish SceneKit screenshot fidelity.

## Public Python API

```python
from cadgen import read_scene, read_step
scene = read_scene("part.step")
print(scene.document_hash)
for occurrence in scene.leaves():
    print(occurrence.ref, occurrence.label, occurrence.prototype_id)
    for selected_face in occurrence.entities("face"):
        face = selected_face.shape()  # owned build123d Face, already placed
        print(selected_face.ref, face.area)
        print([e.ref for e in selected_face.entities("edge")])
        points, triangles = face.tessellate(0.001, angular_tolerance=0.15)
selection = scene.resolve("part.step#o1.f1")
```

Use `occurrence.entities("edge")`, `entities("vertex")`, and `entities("shape")` analogously. Shape refs (`sN`) decompose into solids, else shells, else the leaf. Use `selection.entities(...)` to retain canonical parent ordinals; do not enumerate `face.edges()` and assign new numbers. `read_step` returns the whole build123d shape but does not by itself provide canonical per-occurrence refs.

The delivered exporter deliberately uses OCP directly for the final triangulation, because build123d 0.11.1's `Shape.mesh` passes `isRelative=True` to OCCT. Our `--tolerance-mm` is an absolute deflection (default 0.08 mm), `--angle-radians` defaults to 0.15:

```python
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRep import BRep_Tool
from OCP.BRepLib import BRepLib_ToolTriangulatedShape
from OCP.TopLoc import TopLoc_Location
mesher = BRepMesh_IncrementalMesh(face.wrapped, 0.08, False, 0.15, False)
loc = TopLoc_Location()
tri = BRep_Tool.Triangulation_s(face.wrapped, loc)
BRepLib_ToolTriangulatedShape.ComputeNormals_s(face.wrapped, tri)
```

Transform each `tri.Node(i)` and `tri.Normal(i)` by `loc.Transformation()`. OCCT indices are one-based; subtract one. Reverse triangle order AND normal direction for `TopAbs_REVERSED`. The exporter does this, samples edge curves using `GCPnts_QuasiUniformDeflection(BRepAdaptor_Curve(edge), tolerance_mm)`, exports exact `area`/`length`, validates buffers and publishes JSON atomically. Degenerate edges keep their canonical ID and two coincident endpoints (zero visible stroke).

## Identity and rendering limits

The inspected upstream source establishes the mapping: `packages/cadgen/src/cadgen/step_scene.py:51` opens the immutable document revision; `:78` forms refs; `:210` obtains canonical maps; `_internal/entity_ordinals.py:22` uses `TopExp.MapShapes_s`. The viewer's `_internal/surface_extract.py:735` uses the same face/edge maps. Repeated instances have distinct occurrence prefixes even when geometry coincides. Refs are stable only within one saved document revision, not persistent feature IDs through remodels. Scene geometry contains saved placements, not sidecar animation/kinematic poses. Vertex refs are native STEP vertices; the SURF viewer bundle has no equivalent native vertex table despite broad wording in the feature guide.

This exporter preserves reference identity, not identical viewer mesh buffers. The current viewer tessellates in JavaScript: `packages/cadgen-js/src/lib/surf/tessellate.js:1625` → `tessellateComponent(index, floats, options)`. Python `extract_surface_component(shape, face_colors=...)` (`_internal/surface_extract.py:735`) produces the `.surf` container; it does not mesh it. For exact viewer triangles, retain that container and run:

```js
import {parseSurf} from './packages/cadgen-js/src/lib/surf/container.js';
import {tessellateComponent} from './packages/cadgen-js/src/lib/surf/tessellate.js';
const {index, floats} = parseSurf(arrayBuffer);
const mesh = tessellateComponent(index, floats); // pin same viewer options/version
// Array.from(mesh.positions), normals, indices; mesh.faceRanges:
// {ord, color, indexStart, indexCount}; offsets/counts count indices, not triangles.
// mesh.edges: {ord, visibilityClass, polyline}; prefix ord with occurrence ID.
```

Use whole-component tessellation for its shared boundary conformity; independently tessellating each JS face loses that guarantee. Prototype meshes must receive occurrence transforms and colors separately. This approach needs Node + Three.js (repo pins Three 0.186.0) but no browser or WebView in the native app. The OCCT export path shipped here needs neither Node nor Chromium. Its independent face meshes/edge samples can have differing boundary sample locations; it is a visualization asset, not a watertight manufacturing mesh. The v1 schema omits STEP face colors, edge display classes, hierarchy above leaf parts and analytic surface metadata. It duplicates repeated occurrence geometry; large assemblies should evolve to prototype instancing/binary buffers. Wire-only STEP has no surface preview and raises. Very large previews may exceed the app's explicit size limits.

## Drawing overlay semantics

Inspected `skills/cad-viewer/SKILL.md`, `references/viewer-features.md`, `skills/cad/SKILL.md`, `references/inspection-and-validation.md`, `skills/engineering-drawing/SKILL.md`, and the corresponding implementations.

Ordinary freehand/line/arrow/double-arrow/rectangle/circle/fill strokes are normalized SCREEN coordinates `(x,y)` in `[0,1]`, top-left origin, not CAD geometry (`drawingGeometry.js`). Rectangles use opposite corners; circles use center and radial endpoint. Defaults: red 4 px stroke, white 8 px halo, round caps/joins; freehand spacing 2.5 px, minimum line length 4 px; erase removes the closest whole stroke within 16 px. Fill analyzes annotation stroke boundaries, not CAD face boundaries, and can mark guessed closures (`drawingCanvas.js`). Camera and drawings are saved as separate tab state fields (`apps/viewer/src/client/workbench/persistence.js:372`), not per-stroke camera locks. Native PencilKit annotations should capture camera/viewport/revision explicitly when used in prompts.

A separate surface-line implementation ray-picks a face, locks the drag to that same reference, and stores 3D endpoints plus UVs. Only planes and cylinders actually project (`CadViewer.js:2551`, `surfaceLineGeometry.js:79`). Cylindrical UV is `[radius*angle, axialDistance]`, not raw OCCT angular U. It renders 48 segments, slightly offset from the surface, with depth testing. `persistence.js:243` explicitly drops surface-line strokes, and current toolbar lists omit that tool: treat it as internal/nonpersistent capability, not a promised feature. Exported v1 lacks the analytic metadata needed to reproduce it exactly.

Engineering drawings are separate generated PDFs: `@eng_drawing` projects hidden-line orthographic views, dimensions and title block (`skills/engineering-drawing/SKILL.md`), unrelated to PencilKit annotations or freehand viewer overlays.

## Dependency and license evidence

Executed successfully on macOS/Python 3.12.5 with cadgen 0.6.6, build123d 0.11.1, cadquery-ocp-novtk 7.9.3.1.1. Package minimum Python is 3.11. Cadgen depends on build123d>=0.11.1,<0.12 and cadquery-ocp-novtk>=7.9,<8, plus ezdxf, matplotlib, pillow, shapely. Fresh imports incur kernel startup cost; keep an exporter worker alive for repeated jobs.

Cadgen/text-to-cad is MIT, copyright 2026 Thompson Labs LLC (`packages/cadgen/LICENSE`). [build123d](https://github.com/gumyr/build123d/blob/dev/NOTICE) and [OCP bindings](https://github.com/CadQuery/OCP/blob/master/LICENSE) are Apache-2.0 (also confirmed in installed package metadata). The native OCCT kernel has [LGPL-2.1](https://github.com/Open-Cascade-SAS/OCCT/blob/master/LICENSE_LGPL_21.txt) plus its [additional exception](https://github.com/Open-Cascade-SAS/OCCT/blob/master/OCCT_LGPL_EXCEPTION.txt). Keep upstream notices when distributing copied code/dependencies; generated STEP/JSON are ordinary output artifacts.

Validation: seven integration tests cover exact digest/reference resolution and STEP metrics, sampled face/edge bounds, triangle winding/unit normals/positive approximate volume, repeated instance placements, sphere pole degeneracies, and exact warm-export equality on the same runtime. The bundled preview is checked against canonical STEP topology and geometry rather than platform-dependent tessellation ordering. Both fresh and bundled meshes must pass normals, winding, per-face area and signed-volume checks. Exact area/length/vertex coordinates allow 1e-7 numerical roundoff; sampled bounds allow the exporter's 0.08 mm deflection plus roundoff, and sampled area/length/volume allow 1% error. No upstream files were changed. Native app rendering and screenshot tests are separate.

## Intermediate native previews

Append `--checkpoint-dir <turn-output>/checkpoints --checkpoint-revision 1` to the
usual export command. The exporter saves `r1/model.step` and `r1/model.cad.json`,
verifies their shared source revision, and atomically publishes `latest.json` last.
Increase the revision for each meaningful valid shape. An existing revision cannot
be rewritten with different bytes, and revision numbers cannot move backwards.
Checkpoint files have the same 1 MB limit as final artifacts. The app polls a
scoped Connect checkpoint endpoint and keeps previews separate from its committed
model. Continue writing the final `model.step` and `model.cad.json` at the requested
output root: an intermediate checkpoint is never a completion receipt.
