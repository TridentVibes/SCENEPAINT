"""Validate and align the shared reconstruction evidence in camera/image space.

The neural network receives RGB only. Other cues constrain its reconstruction,
not undocumented network inputs. Color alone is not a geometry discontinuity.
"""
import hashlib,json
from pathlib import Path
import numpy as np
from PIL import Image

def resized(a,size,nearest=False):
 return np.asarray(Image.fromarray(a).resize(size,Image.Resampling.NEAREST if nearest else Image.Resampling.BILINEAR))

def load_evidence(photo,scene_path,size,mask_paths=()):
 w,h=size;rgb=np.asarray(photo.convert('RGB').resize(size,Image.Resampling.BILINEAR),dtype=np.uint8)
 result={'rgb':rgb,'prior':None,'masks':[],'classes':None}
 audit={'neuralInputs':['RGB image','detail token count'],'fusionInputs':['independent model normals','camera-space model depth','source RGB edges'],
        'coordinateSystem':'x right, y down, z forward; normalized pixel-center UV','masks':[]}
 if not scene_path:return result,audit
 scene=json.loads(Path(scene_path).read_text());sw=int(scene['width']);sh=int(scene['height'])
 if not (1<=sw<=1024 and 1<=sh<=1024):raise ValueError('Invalid analysis dimensions')
 cached=np.asarray(scene['rgb'],np.uint8).reshape(sh,sw,3)
 # Compare in the same orientation and crop before accepting any cached map.
 target=(min(w,160),min(h,160));a=resized(rgb,target).astype(float)/255;b=resized(cached,target).astype(float)/255
 error=float(np.mean(abs(a-b)));variance=float(np.std(a))
 correlation=float(np.corrcoef(a.mean(-1).ravel(),b.mean(-1).ravel())[0,1]) if np.std(a.mean(-1))>.005 and np.std(b.mean(-1))>.005 else None
 if error>.12 or (correlation is not None and correlation<.9):
  raise ValueError('Cached maps do not match this photo/orientation. Analyze Photo again before rebuilding.')
 prior=np.asarray(scene['depth'],np.float32).reshape(sh,sw)
 if not np.isfinite(prior).all() or np.any((prior<0)|(prior>1)):raise ValueError('Invalid normalized inverse-depth prior')
 result['prior']=resized(prior,size)
 audit.update({'analysis':Path(scene_path).name,'alignmentMeanError':error,'alignmentCorrelation':correlation,'analysisDimensions':[sw,sh],'fusionDimensions':[w,h],
  'analysisSHA256':hashlib.sha256(Path(scene_path).read_bytes()).hexdigest()})
 audit['fusionInputs'].append('aligned inverse-depth prior')
 for path in dict.fromkeys(mask_paths):
  raw=Path(path).read_bytes()
  if len(raw)!=sw*sh:raise ValueError('Surface mask dimensions do not match photo analysis: '+Path(path).name)
  mask=resized(np.frombuffer(raw,np.uint8).reshape(sh,sw),size,True)>.5*255
  if mask.any() and not mask.all():result['masks'].append(mask)
  audit['masks'].append({'asset':Path(path).name,'sha256':hashlib.sha256(raw).hexdigest(),'selectedPixels':int(mask.sum())})
 if result['masks']:audit['fusionInputs'].append('surface-mask boundaries')
 if scene.get('classes') is not None and scene.get('segmentationAvailable',False):
  classes=np.asarray(scene['classes'],np.uint8).reshape(sh,sw)
  if len(np.unique(classes))>1:result['classes']=resized(classes,size,True);audit['fusionInputs'].append('semantic class boundaries')
 audit['materialCues']='Source color/luminance retained for rendering; albedo/shading previews are not treated as measured geometry.'
 return result,audit

def boundaries(depth,normal,valid,evidence):
 n=normal/np.maximum(np.linalg.norm(normal,axis=-1,keepdims=True),1e-8);rgb=evidence['rgb'].astype(float)/255
 result=[]
 for axis in (1,0):
  a=(slice(None),slice(None,-1)) if axis==1 else (slice(None,-1),slice(None))
  b=(slice(None),slice(1,None)) if axis==1 else (slice(1,None),slice(None))
  relative=abs(depth[a]-depth[b])/np.maximum(np.minimum(depth[a],depth[b]),1e-6)
  normal_jump=np.sum(n[a]*n[b],axis=-1)<.94
  color=np.linalg.norm(rgb[a]-rgb[b],axis=-1)>.18
  # Color supports a geometric cue; printed lines and shadows alone do not cut a mesh.
  edge=~valid[a]|~valid[b]|(relative>.06)|normal_jump|(color&(relative>.018))
  for mask in evidence['masks']:edge|=mask[a]!=mask[b]
  if evidence['classes'] is not None:edge|=evidence['classes'][a]!=evidence['classes'][b]
  result.append(edge)
 return tuple(result)


def region_labels(valid,barriers):
 from scipy import sparse
 from scipy.sparse.csgraph import connected_components
 h,w=valid.shape;indices=np.arange(h*w).reshape(h,w);aa=[];bb=[]
 for axis in (1,0):
  a=(slice(None),slice(None,-1)) if axis==1 else (slice(None,-1),slice(None))
  b=(slice(None),slice(1,None)) if axis==1 else (slice(1,None),slice(None))
  allowed=valid[a]&valid[b]&~barriers[0 if axis else 1]
  aa.extend(indices[a][allowed]);bb.extend(indices[b][allowed])
 graph=sparse.coo_matrix((np.ones(len(aa),np.uint8),(aa,bb)),shape=(h*w,h*w)).tocsr()
 _,labels=connected_components(graph,directed=False)
 return labels.reshape(h,w).astype('<u4')
