"""Conservative planar patches from independent normals; curved surfaces stay curved."""
import numpy as np
from scipy import ndimage

def preserve_planes(depth,normal,valid,fx,fy,barriers=None):
 h,w=depth.shape
 # Average normals only inside very similar neighborhoods; never across a corner.
 length=np.linalg.norm(normal,axis=-1);n=normal/np.maximum(length[...,None],1e-8)
 labels=np.full((h,w),-1,np.int32);regions=[]
 flat=n.reshape(-1,3);usable=(valid&(length>.5)).ravel();lab=labels.ravel()
 for seed in np.flatnonzero(usable):
  if lab[seed]>=0:continue
  reference=flat[seed];group=[int(seed)];lab[seed]=len(regions);head=0
  while head<len(group):
   i=group[head];head+=1;x=i%w;y=i//w
   for j in (i-1 if x>0 else -1,i+1 if x+1<w else -1,i-w if y>0 else -1,i+w if y+1<h else -1):
    if j<0 or lab[j]>=0 or not usable[j]:continue
    if barriers is not None:
     blocked=(barriers[0][y,x-1] if j==i-1 else barriers[0][y,x] if j==i+1 else barriers[1][y-1,x] if j==i-w else barriers[1][y,x])
     if blocked:continue
    if np.dot(flat[j],reference)<.966 or np.dot(flat[j],flat[i])<.94:continue
    lab[j]=len(regions);group.append(j)
  regions.append(np.array(group,dtype=np.int32))
 u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h)
 rays=np.stack([(u-.5)/fx,(v-.5)/fy,np.ones_like(u)],-1).reshape(-1,3)
 z=depth.ravel().astype(float);positions=rays*z[:,None];planes={};counts=[]
 for label,indices in enumerate(regions):
  if len(indices)<60:continue
  samples=flat[indices];mean=samples.mean(0);mean/=max(1e-8,np.linalg.norm(mean))
  spread=np.degrees(np.arccos(np.clip(samples@mean,-1,1)))
  # Consistent orientation is essential: a cylindrical band is not a flat face.
  if np.quantile(spread,.8)>5.5:continue
  d=np.median(positions[indices]@mean);den=rays[indices]@mean
  projected=d/np.where(abs(den)>1e-8,den,1e-8)
  error=abs(projected/z[indices]-1)
  if np.quantile(error,.75)>.30 or np.mean(projected>0)<.98:continue
  planes[label]=[mean,d,indices];counts.append(len(indices))
 # Fill a narrow normal-transition band from the nearest accepted flat face.
 # This avoids leaving the original smoothed ramp between otherwise distinct planes.
 if planes:
  accepted=np.isin(labels,list(planes));distance,nearest=ndimage.distance_transform_edt(~accepted,return_indices=True)
  extended=labels[nearest[0],nearest[1]]
  work=np.where((distance<=4)&valid,extended,labels)
 else:work=labels
 # Keep adjacent flat faces distinct. Small model deviations around a right angle
 # are corrected symmetrically, rather than interpolating an artificial ramp.
 neighbors=set()
 for a,b in [(work[:,:-1],work[:,1:]),(work[:-1],work[1:])]:
  for i,j in np.unique(np.stack([a.ravel(),b.ravel()],-1),axis=0):
   if i!=j and i in planes and j in planes:neighbors.add((min(int(i),int(j)),max(int(i),int(j))))
 corners=0
 for i,j in neighbors:
  a,da,ia=planes[i];b,db,ib=planes[j];dot=float(a@b)
  if abs(dot)<.17:
   # Retain both plane anchors; snap the small angular error only.
   b=b-a*dot;b/=np.linalg.norm(b);planes[j][0]=b
   planes[j][1]=np.median(positions[ib]@b);corners+=1
 out=z.copy()
 for mean,d,indices in planes.values():
  den=rays[indices]@mean;projected=d/np.where(abs(den)>1e-8,den,1e-8)
  ok=(projected>0)&(abs(projected/z[indices]-1)<.35)
  out[indices[ok]]=projected[ok]
  extra=np.flatnonzero((work.ravel()==next(k for k,v in planes.items() if v[2] is indices))&(labels.ravel()!=work.ravel()))
  if len(extra):
   if barriers is not None:
    edge=np.zeros((h,w),bool);edge[:,:-1]|=barriers[0];edge[:,1:]|=barriers[0];edge[:-1]|=barriers[1];edge[1:]|=barriers[1]
    extra=extra[~ndimage.binary_dilation(edge,iterations=1).ravel()[extra]]
   denom=rays[extra]@mean;candidate=d/np.where(abs(denom)>1e-8,denom,1e-8)
   keep=(candidate>0)&(abs(candidate/z[extra]-1)<.25)&((flat[extra]@mean)>.65)
   out[extra[keep]]=candidate[keep]
 out[~valid.ravel()]=0
 return out.reshape(h,w).astype(np.float32),{'planarPatches':len(planes),'planarPixels':sum(counts),'rightAnglePairs':corners,'normalRegions':len(regions),'patches':[{'label':int(k),'normal':a.tolist(),'area':len(i),'boundsUV':[float((i%w).min()/w),float((i//w).min()/h),float((i%w).max()/w),float((i//w).max()/h)]} for k,(a,d,i) in planes.items()]}
