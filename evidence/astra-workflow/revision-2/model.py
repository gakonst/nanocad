"""Resolve the exact first-revision prompt reference and widen only its hole."""
from pathlib import Path
import hashlib, json
import build123d as bd
from cadgen import read_scene
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.GeomAbs import GeomAbs_Cylinder
root=Path(__file__).resolve().parent.parent
context=json.loads((root/'prompt-context.json').read_text())
source=root/context['input_step']
assert hashlib.sha256(source.read_bytes()).hexdigest()==context['revision']
scene=read_scene(source)
selection=scene.resolve(context['references'][0])
a=BRepAdaptor_Surface(selection.shape().wrapped)
assert a.GetType()==GeomAbs_Cylinder and abs(a.Cylinder().Radius()-2)<1e-7
c=a.Cylinder(); p=c.Location(); direction=c.Axis().Direction()
assert abs(abs(direction.Z())-1)<1e-7
plate=bd.import_step(source)
plate-=bd.Pos(p.X(),p.Y(),-1)*bd.Cylinder(3,7,align=(bd.Align.CENTER,bd.Align.CENTER,bd.Align.MIN))
plate.label='Mounting plate'
bd.export_step(plate,Path(__file__).with_suffix('.step'),timestamp='2026-09-24T00:00:00')
