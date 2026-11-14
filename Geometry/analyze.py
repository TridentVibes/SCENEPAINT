"""Local MoGe-2 Base ONNX runner. Focal fitting follows Microsoft's MoGe geometry_numpy.py.
Source: https://github.com/microsoft/MoGe (MIT/Apache notices in Geometry/NOTICE.md).
No image is uploaded. All outputs are written beside the external-drive project.
"""
import os
os.environ.setdefault('OMP_NUM_THREADS','8')
import argparse,json,time,struct,resource
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener
register_heif_opener()
import onnxruntime as ort
ort.disable_telemetry_events()
from scipy.optimize import least_squares
p=argparse.ArgumentParser();p.add_argument('image');p.add_argument('output');p.add_argument('--tokens',type=int,default=1200);p.add_argument('--depth-prior');p.add_argument('--wall-mask',action='append',default=[]);p.add_argument('--no-completion',action='store_true');p.add_argument('--surface-mask',action='append',default=[]);a=p.parse_args()
root=Path(__file__).resolve().parent.parent
start=time.perf_counter()
opt=ort.SessionOptions();opt.intra_op_num_threads=8;opt.inter_op_num_threads=1
session=ort.InferenceSession(str(root/'Models/MoGe2Base/model.onnx'),sess_options=opt,providers=['CPUExecutionProvider'])
print(json.dumps({'stage':'loaded','inputs':[(x.name,x.shape,x.type) for x in session.get_inputs()],'seconds':time.perf_counter()-start}),flush=True)
photo=ImageOps.exif_transpose(Image.open(a.image)).convert('RGB');photo.thumbnail((518,518),Image.Resampling.LANCZOS)
w,h=photo.size;image=np.asarray(photo,dtype=np.float32).transpose(2,0,1)[None]/255
inputs={'image':image}
for x in session.get_inputs():
 if x.name=='num_tokens':inputs[x.name]=np.array(a.tokens,dtype=np.int64)
 elif x.name!='image':raise ValueError('Unsupported neural input: '+x.name)
t=time.perf_counter();outputs=session.run(None,inputs);elapsed=time.perf_counter()-t
print(json.dumps({'stage':'inferred','seconds':elapsed}),flush=True)
values=dict(zip([o.name for o in session.get_outputs()],outputs))
if not {'points','normal','mask'}.issubset(values):raise ValueError('Geometry model lacks required point, normal or validity output')
points=values['points'][0];mask=values['mask'][0]>0.5
if points.shape!=(h,w,3) or values['normal'][0].shape!=(h,w,3) or mask.shape!=(h,w):raise ValueError('Geometry model output dimensions do not match RGB input')
mask &= np.isfinite(values['normal'][0]).all(-1)&(np.linalg.norm(values['normal'][0],axis=-1)>.5)
if mask.sum()<32:raise ValueError('Insufficient reliable geometry samples')
aspect=w/h;sx=aspect/(1+aspect*aspect)**.5;sy=1/(1+aspect*aspect)**.5
u,v=np.meshgrid(np.linspace(-sx*(w-1)/w,sx*(w-1)/w,w),np.linspace(-sy*(h-1)/h,sy*(h-1)/h,h));uv=np.stack([u,v],axis=-1)
valid=mask & np.isfinite(points).all(-1);xy=points[valid,:2][::8];z=points[valid,2][::8];target=uv[valid][::8]
def residual(shift):
 proj=xy/(z+shift)[:,None];f=(proj*target).sum()/np.square(proj).sum();return (f*proj-target).ravel()
shift=float(least_squares(residual,x0=0,ftol=1e-3,method='lm').x[0]);proj=xy/(z+shift)[:,None];focal=float((proj*target).sum()/np.square(proj).sum())
if not np.isfinite(focal) or focal<=0:raise ValueError('Invalid focal estimate')
metric=float(np.asarray(values.get('metric_scale',values.get('scale',1))).ravel()[0])
if not np.isfinite(metric) or metric<=0:raise ValueError('Invalid model scale')
depth=(points[...,2]+shift)*metric
valid &= np.isfinite(depth)&(depth>0)
normal=np.asarray(values['normal'][0],dtype=np.float32);normal /= np.maximum(1e-8,np.linalg.norm(normal,axis=-1,keepdims=True));normal[~valid]=0
np.savez_compressed(Path(a.output).with_suffix('.raw.npz'),depth=depth,normal=normal,valid=valid,fx=focal/(2*sx),fy=focal/(2*sy))
print(json.dumps({'stage':'refining'}),flush=True)
from refine import refine
from fusion import load_evidence,boundaries,region_labels
# All auxiliary evidence is checked against the original photograph before use.
evidence,fusion_audit=load_evidence(photo,a.depth_prior,(w,h),a.surface_mask+a.wall_mask)
prior=evidence['prior'];barriers=boundaries(depth,normal,valid,evidence)
depth,refinement=refine(depth,normal,valid,focal/(2*sx),focal/(2*sy),prior,barriers)
refinement['evidenceFusion']=fusion_audit
completion={'version':1,'groups':[]}
if not a.no_completion:
 print(json.dumps({'stage':'completion'}),flush=True)
 from object_completion import complete_objects
 completion['groups']=complete_objects(depth,normal,valid,focal/(2*sx),focal/(2*sy),refinement.get('patches',()),barriers)
if a.wall_mask:
 masks=[]
 for path in a.wall_mask:
  if prior is None:raise ValueError('Wall constraints require the photo analysis dimensions')
  scene=json.loads(Path(a.depth_prior).read_text())
  raw=np.frombuffer(Path(path).read_bytes(),dtype=np.uint8).reshape(scene['height'],scene['width'])
  masks.append(np.asarray(Image.fromarray(raw).resize((w,h),Image.Resampling.BILINEAR))/255)
 if not a.no_completion:
  from completion import complete_walls,wall_groups
  structure=complete_walls(depth,normal,valid,focal/(2*sx),focal/(2*sy),masks)
  completion['groups']+=wall_groups(structure)
  refinement['structuralCompletion']=structure
 # Keep the observed depth and normals intact. A wall hypothesis supplements
 # them; a mixed/unsupported selection must never tilt the floor raster.
print(json.dumps({'stage':'saving'}),flush=True)
xyz=np.dstack([u*depth/focal,v*depth/focal,depth]).astype('<f4');xyz[~valid]=0
# Geometry uses normalized image UV and camera-space positions. Header is versioned little endian.
out=Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
labels=region_labels(valid,barriers)
with out.with_suffix('.spregion').open('wb') as file:
 file.write(b'SPREG001');file.write(struct.pack('<II',w,h));file.write(labels.tobytes())
import hashlib
fusion_audit['sourceSHA256']=hashlib.sha256(Path(a.image).read_bytes()).hexdigest()
fusion_audit['camera']={'fx':focal/(2*sx),'fy':focal/(2*sy),'cx':.5,'cy':.5}
fusion_audit['barrierCounts']=[int(x.sum()) for x in barriers]
out.with_suffix('.fusion.json').write_text(json.dumps(fusion_audit,indent=2,allow_nan=False))
out.with_suffix('.completion.json').write_text(json.dumps(completion,allow_nan=False))
refinement['completionGroups']=[{'kind':g['kind'],'confidence':g['confidence'],'triangles':len(g['faces'])} for g in completion['groups']]
fx=focal/(2*sx);fy=focal/(2*sy)
with out.open('wb') as file:
 file.write(b'SPGEO001');file.write(struct.pack('<IIff',w,h,fx,fy));file.write(xyz.tobytes())
with out.with_suffix('.spnormal').open('wb') as file:
 file.write(b'SPNOR001');file.write(struct.pack('<II',w,h));file.write(normal.astype('<f4').tobytes())
normal_image=(np.clip(normal*.5+.5,0,1)*255).astype(np.uint8);normal_image[~valid]=0
Image.fromarray(normal_image).save(out.with_suffix('.normal.png'))
info={'engine':'MoGe-2 Base ONNX CPU','width':w,'height':h,'fx':fx,'fy':fy,'fovX':float(np.degrees(2*np.arctan(.5/fx))),'inferenceSeconds':elapsed,'totalSeconds':time.perf_counter()-start,'peakResidentMB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024/1024,'validFraction':float(valid.mean()),'tokens':a.tokens,'providers':session.get_providers(),'refinement':refinement}
out.with_suffix('.json').write_text(json.dumps(info,indent=2));print(json.dumps(info),flush=True)
