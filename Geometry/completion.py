"""Small structural hypotheses from image-space wall/floor contact.

Only explicitly identified wall faces participate. Dimensions are relative to the
estimated camera, never metric measurements. Observed rasters remain unchanged.
"""
import numpy as np
from scipy import ndimage

def _complete_walls(depth, normal, valid, fx, fy, masks):
 h,w=depth.shape
 n=normal/np.maximum(np.linalg.norm(normal,axis=-1,keepdims=True),1e-8)
 floor=valid&(n[...,1]<-.88)
 if floor.sum()<50:return {'version':1,'walls':[],'reason':'No reliable floor'}
 up=np.median(n[floor],axis=0);up/=np.linalg.norm(up)
 u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h)
 rays=np.stack([(u-.5)/fx,(v-.5)/fy,np.ones_like(u)],-1)
 xyz=rays*depth[...,None]
 floor_offset=float(np.median(xyz[floor]@up))
 denominator=rays@up
 floor_depth=floor_offset/np.where(abs(denominator)>1e-6,denominator,1e-6)
 floor_xyz=rays*floor_depth[...,None]
 walls=[]
 for index,mask in enumerate(masks):
  selected=(mask>.5)&valid
  contact=ndimage.binary_dilation(selected,iterations=2)&~selected&floor&(floor_depth>0)
  # A local floor boundary is essential; a random vertical object is insufficient.
  if selected.sum()<12 or contact.sum()<16:continue
  p=floor_xyz[contact];center=np.median(p,axis=0)
  # Fit the complete contact strip: selecting a single dense sub-line can
  # mistake the upper border of a narrow face for its ground contact.
  tolerance=max(.005,float(np.median(depth[selected]))*.004)
  _,singular,vh=np.linalg.svd(p-center,full_matrices=False)
  if singular[0]<tolerance*8 or singular[1]>singular[0]*.22:continue
  tangent=vh[0]-up*(vh[0]@up);tangent/=np.linalg.norm(tangent)
  best=np.ones(len(p),dtype=bool)
  inward=np.cross(tangent,up);inward/=np.linalg.norm(inward)
  # Which side contains the visible floor? Compare each contact to its closest
  # selected wall pixel at the same image scale; do not assume camera-facing.
  _,nearest=ndimage.distance_transform_edt(~selected,return_indices=True)
  yy,xx=np.where(contact);nearest_floor=floor_xyz[nearest[0,yy,xx],nearest[1,yy,xx]]
  direction=np.median((p-nearest_floor)@inward)
  if direction<0:inward=-inward
  offset=float(center@inward)
  wall_den=rays@inward
  wall_depth=offset/np.where(abs(wall_den)>1e-6,wall_den,1e-6)
  projected=rays*wall_depth[...,None]
  heights=projected@up-floor_offset
  reliable=selected&(wall_depth>0)&(heights>tolerance)&(heights<np.median(depth[selected])*.5)
  if reliable.sum()<12:continue
  height=float(np.percentile(heights[reliable],95))
  along=projected[reliable]@tangent
  lo,hi=np.percentile(along,[1,99]);length=float(hi-lo)
  if length<height:continue
  # Height is evidence-derived. Thickness starts as an explicit low-confidence
  # structural prior; cap-normal evidence below can replace it.
  thickness=height*.22;thickness_source='proportional prior'
  ring=ndimage.binary_dilation(selected,iterations=5)&~selected&valid
  cap=ring&(np.abs(n@up)>.88)&((xyz@up-floor_offset)>height*.55)&((xyz@up-floor_offset)<height*1.6)
  widths=-(xyz[cap]@inward-offset)
  widths=widths[(widths>height*.04)&(widths<height*.8)]
  if len(widths)>=8:thickness=float(np.percentile(widths,85));thickness_source='visible cap'
  base=center+tangent*(lo-center@tangent)
  end=center+tangent*(hi-center@tangent)
  confidence=float(min(.85,.4+.3*min(1,reliable.sum()/400)+.1*max(0,1-singular[1]/singular[0]*5)))
  walls.append({'baseA':base.tolist(),'baseB':end.tolist(),'up':up.tolist(),'inward':inward.tolist(),
   'height':height,'thickness':thickness,'confidence':confidence,'maskIndex':index,
   'supportPixels':int(best.sum()),'facePixels':int(reliable.sum()),'heightSource':'visible face',
   'thicknessSource':thickness_source,'inferredFaces':['top','outside'],'floorOffset':floor_offset})
 # Transfer only between opposing, nearly parallel faces on this same support.
 # Better coverage supplies the common height; perspective remains camera-based.
 for target in walls:
  donors=[x for x in walls if x is not target and np.dot(x['inward'],target['inward'])<-.85
          and x['facePixels']>target['facePixels']*1.5]
  if not donors:continue
  donor=max(donors,key=lambda x:x['facePixels'])
  ratio=target['height']/donor['height']
  if .25<ratio<4 or target['confidence']<.65:
   target['height']=donor['height'];target['heightSource']='matching wall';target['heightDonor']=donor['maskIndex']
   if target['thicknessSource']=='proportional prior':
    target['thickness']=donor['thickness'];target['thicknessSource']='matching wall ('+donor['thicknessSource']+')'
 return {'version':1,'walls':walls,'floorNormal':up.tolist(),'floorOffset':floor_offset}

def wall_groups(completion):
 groups=[]
 for wall in completion['walls']:
  a=np.array(wall['baseA']);b=np.array(wall['baseB']);up=np.array(wall['up']);inward=np.array(wall['inward'])
  h=up*wall['height'];out=-inward*wall['thickness'];t=unit_vector(b-a)
  vertices=np.array([a,b,a+h,b+h,a+out,b+out,a+h+out,b+h+out])
  faces=[]
  for quad,n in [([0,1,3,2],inward),([2,3,7,6],up),([4,6,7,5],-inward),([0,2,6,4],-t),([1,5,7,3],t)]:
   for tri in [[quad[0],quad[1],quad[2]],[quad[0],quad[2],quad[3]]]:
    if np.cross(vertices[tri[1]]-vertices[tri[0]],vertices[tri[2]]-vertices[tri[0]])@n<0:tri=tri[::-1]
    faces.append(tri)
  groups.append({'kind':'wall','confidence':wall['confidence'],'vertices':vertices.tolist(),'faces':faces,'inferred':True,'dimensions':wall})
 return groups

def unit_vector(x):return x/max(1e-8,np.linalg.norm(x))

def complete_walls(depth,normal,valid,fx,fy,masks):
 # Curved or stepped boundaries need multiple wall sections, not one forced
 # plane. Split unsupported selections using their normal field, then refit.
 first=_complete_walls(depth,normal,valid,fx,fy,masks)
 accepted={w['maskIndex'] for w in first['walls']};expanded=[];source=[]
 n=normal/np.maximum(np.linalg.norm(normal,axis=-1,keepdims=True),1e-8)
 for i,mask in enumerate(masks):
  if i in accepted:expanded.append(mask);source.append(i);continue
  selected=(mask>.5)&valid
  keys=np.round(n[selected]*3).astype(int)
  if not len(keys):continue
  bins,counts=np.unique(keys,axis=0,return_counts=True)
  used=np.zeros_like(valid)
  for key in bins[np.argsort(counts)[::-1]][:16]:
   direction=unit_vector(key.astype(float))
   region=selected&~used&((n@direction)>.96)
   labels,count=ndimage.label(region)
   for label in range(1,count+1):
    patch=labels==label
    if patch.sum()<40:continue
    used|=patch;expanded.append(patch.astype(float));source.append(i)
 if not expanded:return first
 result=_complete_walls(depth,normal,valid,fx,fy,expanded)
 for wall in result['walls']:
  wall['selectionIndex']=source[wall['maskIndex']]
 return result
