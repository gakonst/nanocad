# Astra CAD workflow smoke test

Astra executed a real generation and selection-aware refinement with the pinned CAD toolchain on 2026-09-24. This exercises the model and native CAD tools, not authenticated delivery through the iOS app. No account credentials were used.

The initial brief requested a 60 × 40 × 5 mm plate, four Ø4 mm through holes at 6 mm offsets, and four 2 mm outer vertical corner fillets. Astra wrote and ran a build123d model, saved STEP, and ran NanoCAD’s exporter.

A second request selected `model.step#o1.f11` in the exact first STEP revision and asked to enlarge only that through hole to Ø6 mm. The refinement script verifies the input digest, resolves the face with `cadgen.read_scene`, reads the native cylinder’s axis and radius, and subtracts the larger bore at that location.

Both saved revisions pass checks for one valid solid, 60 × 40 × 5 mm bounds, all four hole centers, through-hole depths, corner fillet radii, analytic volume, reference resolution, JSON/STEP digest agreement, native areas, and mesh bounds. The second revision has exactly one radius-3 mm bore and three radius-2 mm bores, with unchanged external bounds, no added material, and the expected volume reduction of 25π mm³. Its STEP digest differs from the first revision.

The independent mesh image was visually reviewed. It shows the selected lower-left bore enlarged, with the other three holes and outer profile preserved. This image is generated from the exported mesh, not a SceneKit framebuffer.

- [Machine-readable checks](../evidence/astra-workflow/evidence.json)
- [Selection context and first-revision digest](../evidence/astra-workflow/prompt-context.json)
- [Initial STEP](../evidence/astra-workflow/revision-1/model.step) and [source](../evidence/astra-workflow/revision-1/model.py)
- [Refined STEP](../evidence/astra-workflow/revision-2/model.step) and [source](../evidence/astra-workflow/revision-2/model.py)
- [Reviewed mesh comparison](../evidence/astra-workflow/mesh-review.png)

Reproduce from the repository root after installing `Tools/requirements.txt`:

```sh
.cadgen-venv/bin/python evidence/astra-workflow/revision-1/model.py
.cadgen-venv/bin/python Tools/export_step.py evidence/astra-workflow/revision-1/model.step
.cadgen-venv/bin/python evidence/astra-workflow/revision-2/model.py
.cadgen-venv/bin/python Tools/export_step.py evidence/astra-workflow/revision-2/model.step
.cadgen-venv/bin/python evidence/astra-workflow/validate_and_render.py
```

The first revision uses a fixed export timestamp. Kernel-version changes can still change STEP serialization or reference ordinals; the second script intentionally refuses a mismatched input digest instead of editing guessed topology.
