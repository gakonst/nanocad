from pathlib import Path
import hashlib, json, math
from cadgen import read_scene
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.GeomAbs import GeomAbs_Cylinder
root=Path(__file__).resolve().parent
step=root/'revision-1/model.step'
scene=read_scene(step)
cylinders=[]
for occ in scene.leaves():
 for selection in occ.entities('face'):
  a=BRepAdaptor_Surface(selection.shape().wrapped)
  if a.GetType()==GeomAbs_Cylinder:
   c=a.Cylinder(); p=c.Location()
   cylinders.append({'ref':selection.ref,'radius_mm':c.Radius(),'axis_origin_mm':[p.X(),p.Y(),p.Z()], 'angular_span_radians':a.LastUParameter()-a.FirstUParameter()})
holes=[c for c in cylinders if abs(c['angular_span_radians']-2*math.pi)<1e-7]
selected=next(c for c in holes if abs(c['axis_origin_mm'][0]-6)<1e-7 and abs(c['axis_origin_mm'][1]-6)<1e-7)
context={'prompt':'Enlarge only the selected through hole to 6 mm diameter. Preserve all other dimensions.', 'references':['model.step'+selected['ref']], 'revision':scene.document_hash, 'input_step':'revision-1/model.step', 'selection_before_edit':selected, 'scene_cylinders':cylinders, 'scope':'Astra model/tool smoke test; no authenticated application or live account API exercised.'}
assert scene.document_hash==hashlib.sha256(step.read_bytes()).hexdigest()
(root/'prompt-context.json').write_text(json.dumps(context,indent=2)+'\n')
print(json.dumps(context,indent=2))
