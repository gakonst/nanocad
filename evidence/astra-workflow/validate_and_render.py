from pathlib import Path
import hashlib, json, math, sys
import build123d as bd
from cadgen import read_scene
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.GeomAbs import GeomAbs_Cylinder
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection,Line3DCollection
import numpy as np
root=Path(__file__).resolve().parent
sys.path.insert(0,str(root.parent.parent/'Tools'))
from export_step import validate_document
context=json.loads((root/'prompt-context.json').read_text())
report={'scope':context['scope'],'coordinate_assumptions':'Origin at lower-left bottom; bounds [0,0,0] to [60,40,5] mm. Hole centers are 6 mm from adjacent straight edges. Fillets apply to four outer vertical edges.', 'prompt_context':context,'revisions':[]}
fig=plt.figure(figsize=(14,6),facecolor='#edf1f5')
models=[]
for revision in (1,2):
 step=root/f'revision-{revision}/model.step'
 shape=bd.import_step(step); models.append(shape)
 scene=read_scene(step); doc=json.loads(step.with_suffix('.cad.json').read_text()); validate_document(doc)
 bb=shape.bounding_box(); bounds=[list(bb.min),list(bb.max)]
 holes=[]; fillets=[]
 for occ in scene.leaves():
  for s in occ.entities('face'):
   a=BRepAdaptor_Surface(s.shape().wrapped)
   if a.GetType()==GeomAbs_Cylinder:
    c=a.Cylinder(); p=c.Location(); sb=s.shape().bounding_box()
    record={'ref':s.ref,'radius_mm':c.Radius(),'center_xy_mm':[p.X(),p.Y()],'z_bounds_mm':[sb.min.Z,sb.max.Z]}
    if abs(a.LastUParameter()-a.FirstUParameter()-2*math.pi)<1e-7: holes.append(record)
    else: fillets.append(record)
 expected_volume=(60*40-4*(4-math.pi))*5-math.pi*(16 if revision==1 else 21)*5
 checks={
 'valid_single_solid':shape.is_valid and len(shape.solids())==1,
 'bounds_60_40_5':all(abs(a-b)<1e-6 for a,b in zip(bounds[0]+bounds[1],[0,0,0,60,40,5])),
 'analytic_volume':abs(shape.volume-expected_volume)<1e-6,
 'four_hole_centers':sorted(h['center_xy_mm'] for h in holes)==[[6.0,6.0],[6.0,34.0],[54.0,6.0],[54.0,34.0]],
 'hole_radii':sorted(round(h['radius_mm'],7) for h in holes)==([2.,2.,2.,2.] if revision==1 else [2.,2.,2.,3.]),
 'through_holes':all(abs(h['z_bounds_mm'][0])<1e-6 and abs(h['z_bounds_mm'][1]-5)<1e-6 for h in holes),
 'four_2mm_corner_fillets':len(fillets)==4 and all(abs(h['radius_mm']-2)<1e-7 for h in fillets) and sorted(h['center_xy_mm'] for h in fillets)==[[2.,2.],[2.,38.],[58.,2.],[58.,38.]],
 'digest':doc['revision']==scene.document_hash==hashlib.sha256(step.read_bytes()).hexdigest(),
 'all_refs_resolve':all(scene.resolve(e['id']) is not None for key in ['faces','edges','vertices','parts'] for e in doc[key]),
 'face_ref_set':{e['id'] for e in doc['faces']}=={s.ref.lstrip('#') for o in scene.leaves() for s in o.entities('face')},
 'preview_areas_match':all(abs(scene.resolve(e['id']).shape().area-e['area'])<1e-7 for e in doc['faces']),
 'preview_contract_valid':True}
 points=np.concatenate([np.asarray(f['positions']).reshape(-1,3) for f in doc['faces']])
 checks['mesh_bounds_match_step']=np.max(abs(points.min(axis=0)-np.asarray(bounds[0])))<1e-6 and np.max(abs(points.max(axis=0)-np.asarray(bounds[1])))<1e-6
 if revision==2: checks['selected_hole_only']=all(abs(h['radius_mm']-(3 if h['center_xy_mm']==[6.,6.] else 2))<1e-7 for h in holes)
 checks={key:bool(value) for key,value in checks.items()}
 assert all(checks.values()),checks
 report['revisions'].append({'revision':revision,'sha256':doc['revision'],'volume_mm3':shape.volume,'expected_volume_mm3':expected_volume,'bounds_mm':bounds,'holes':holes,'fillets':fillets,'faces':len(doc['faces']),'triangles':sum(len(f['indices'])//3 for f in doc['faces']),'checks':checks})
 ax=fig.add_subplot(1,2,revision,projection='3d',facecolor='#edf1f5')
 for f in doc['faces']:
  pts=np.asarray(f['positions']).reshape(-1,3); indices=np.asarray(f['indices']).reshape(-1,3)
  ax.add_collection3d(Poly3DCollection(pts[indices],facecolors='#8eadd0',linewidths=0,shade=True))
 for e in doc['edges']:
  pts=np.asarray(e['points']).reshape(-1,3)
  ax.add_collection3d(Line3DCollection([[a,b] for a,b in zip(pts,pts[1:])],colors='#23405e',linewidths=.65))
 ax.set(xlim=(-5,65),ylim=(-5,45),zlim=(-3,9)); ax.set_box_aspect((70,50,12)); ax.view_init(elev=58,azim=-68); ax.set_axis_off()
 ax.set_title(f'Revision {revision}: '+('four Ø4 mm holes' if revision==1 else 'selected (6, 6) hole → Ø6 mm'))
report['cross_revision_checks']={'bounds_unchanged':report['revisions'][0]['bounds_mm']==report['revisions'][1]['bounds_mm'],'revision_changed':report['revisions'][0]['sha256']!=report['revisions'][1]['sha256'],'volume_decrease_25pi':abs(models[0].volume-models[1].volume-25*math.pi)<1e-6,'no_material_added':abs((models[1]-models[0]).volume)<1e-6}
assert all(report['cross_revision_checks'].values())
report['all_checks_pass']=True
(root/'evidence.json').write_text(json.dumps(report,indent=2)+'\n')
fig.suptitle('Astra CAD tool smoke test · saved STEP → OCCT preview mesh',fontsize=16)
fig.text(.5,.03,'60 × 40 × 5 mm · 2 mm vertical corner fillets · independent offline mesh rendering',ha='center')
fig.savefig(root/'mesh-review.png',dpi=140,bbox_inches='tight')
print(json.dumps({'all_checks_pass':True,'revisions':[{k:r[k] for k in ['revision','sha256','volume_mm3','bounds_mm','holes']} for r in report['revisions']],'cross_revision_checks':report['cross_revision_checks']},indent=2))
