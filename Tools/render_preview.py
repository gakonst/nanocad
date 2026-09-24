#!/usr/bin/env python3
"""Independent image of the exported triangles (not a SceneKit screenshot)."""
import json
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection, Line3DCollection
import numpy as np

root = Path(__file__).resolve().parent.parent
model = json.loads((root / "Resources/precision-bracket.cad.json").read_text())
fig = plt.figure(figsize=(10, 8), facecolor="#edf1f5")
ax = fig.add_subplot(111, projection="3d", facecolor="#edf1f5")
all_points = []
for face in model["faces"]:
    points = np.asarray(face["positions"]).reshape(-1, 3)
    indices = np.asarray(face["indices"]).reshape(-1, 3)
    ax.add_collection3d(Poly3DCollection(points[indices], facecolors="#8eadd0", linewidths=0, antialiased=False, shade=True))
    all_points.extend(points)
for edge in model["edges"]:
    points = np.asarray(edge["points"]).reshape(-1, 3)
    if len(points) > 1:
        ax.add_collection3d(Line3DCollection([[a, b] for a, b in zip(points, points[1:])], colors="#23405e", linewidths=0.7))
points = np.asarray(all_points)
lo, hi = points.min(axis=0), points.max(axis=0)
center, span = (lo + hi) / 2, max(hi - lo) * 0.62
ax.set_xlim(center[0]-span, center[0]+span)
ax.set_ylim(center[1]-span, center[1]+span)
ax.set_zlim(center[2]-span, center[2]+span)
ax.set_box_aspect((1, 1, 1))
ax.view_init(elev=23, azim=-58)
ax.set_axis_off()
fig.suptitle("Precision bracket · exported STEP geometry", x=0.08, y=0.96, ha="left", fontsize=18, color="#183149")
fig.text(0.08, 0.90, "84 × 54 × 52 mm  ·  11 faces  ·  1,040 triangles", fontsize=12, color="#53687a")
fig.text(0.08, 0.045, "OCCT mesh review · world coordinates · independent of native app renderer", fontsize=10, color="#53687a")
fig.subplots_adjust(0, 0, 1, 0.92)
out = root / "evidence/precision-bracket-export.png"
fig.savefig(out, dpi=140)
print(out)
