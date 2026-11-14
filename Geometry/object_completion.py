"""Bounded geometric completion across the whole photo, without another model.

Uses normal/depth continuity rather than object names. Reliable analytic fits can
complete curved backs; unsupported irregular patches only receive small local
extensions. A fit is a hypothesis, not recovered ground truth.
"""
import numpy as np
from scipy import sparse,ndimage
from scipy.sparse.csgraph import connected_components
from scipy.spatial import ConvexHull,QhullError

def unit(x):return x/max(1e-10,np.linalg.norm(x))

def fit_surface(points,normals):
 p=np.asarray(points);n=np.asarray(normals);center=np.median(p,axis=0)
 # Normal equations p = center + radius * normal constrain size from both
 # appearance-derived normals and observed XYZ, including shallow visible arcs.
 candidates=[]
 m=unit(n.mean(0));spread=np.quantile(np.linalg.norm(n-m,axis=1),.8)
 if spread<.13:
  error=np.quantile(abs((p-center)@m),.8)
  scale=np.linalg.norm(np.ptp(p,axis=0))
  if error<max(1e-5,scale*.025):return {'kind':'plane','normal':m,'center':center,'error':float(error/max(scale,1e-8))}
 a=np.zeros((len(p)*3,4));b=p.ravel()
 for k in range(3):a[k::3,k]=1;a[k::3,3]=n[:,k]
 x=np.linalg.lstsq(a,b,rcond=None)[0];r=x[3]
 if r>0:
  radial=p-x[:3];pred=radial/np.maximum(np.linalg.norm(radial,axis=1,keepdims=True),1e-8)
  error=np.quantile(abs(np.linalg.norm(radial,axis=1)-r),.8)/r
  if error<.075 and np.mean(np.sum(pred*n,axis=1))>.95 and np.linalg.eigvalsh(np.cov(n.T))[0]>.008:
   candidates.append({'kind':'sphere','center':x[:3],'radius':r,'error':float(error)})
 values,vectors=np.linalg.eigh(np.cov(n.T));axis=vectors[:,0]
 e=unit(np.cross(axis,[1,0,0] if abs(axis[0])<.8 else [0,1,0]));f=np.cross(axis,e)
 q=np.stack([p@e,p@f],-1);nn=np.stack([n@e,n@f],-1)
 a=np.zeros((len(p)*2,3))
 for k in range(2):a[k::2,k]=1;a[k::2,2]=nn[:,k]
 x=np.linalg.lstsq(a,q.ravel(),rcond=None)[0];r=x[2]
 if r>0 and values[1]>.008 and values[0]<values[1]*.15:
  radial=q-x[:2];error=np.quantile(abs(np.linalg.norm(radial,axis=1)-r),.8)/r
  pred=radial/np.maximum(np.linalg.norm(radial,axis=1,keepdims=True),1e-8)
  if error<.075 and np.mean(np.sum(pred*nn,axis=1))>.94:
   lo,hi=np.percentile(p@axis,[1,99])
   if hi-lo>r*.5:candidates.append({'kind':'cylinder','center':e*x[0]+f*x[1],'axis':axis,'e':e,'f':f,'radius':r,'lo':lo,'hi':hi,'error':float(error)})
 return min(candidates,key=lambda c:c['error']) if candidates else {'kind':'local','center':center,'normal':m,'error':1.}

def surface_mesh(fit,points):
 p=np.asarray(points);vertices=[];faces=[];kind=fit['kind']
 if kind=='sphere':
  c=fit['center'];r=fit['radius'];vertices=[c+[0,0,r]]
  for j in range(1,16):
   theta=np.pi*j/16
   for i in range(32):
    a=i*2*np.pi/32;vertices.append(c+r*np.array([np.sin(theta)*np.cos(a),np.sin(theta)*np.sin(a),np.cos(theta)]))
  south=len(vertices);vertices.append(c+[0,0,-r])
  for i in range(32):faces.append([0,1+i,1+(i+1)%32]);faces.append([south,1+14*32+(i+1)%32,1+14*32+i])
  for j in range(14):
   for i in range(32):
    a=1+j*32+i;b=1+j*32+(i+1)%32;c=a+32;d=b+32;faces.extend([[a,c,b],[b,c,d]])
 elif kind=='cylinder':
  for j in range(9):
   z=fit['lo']+(fit['hi']-fit['lo'])*j/8
   for i in range(48):
    a=i*2*np.pi/48;vertices.append(fit['center']+fit['axis']*z+fit['radius']*(fit['e']*np.cos(a)+fit['f']*np.sin(a)))
  for j in range(8):
   for i in range(48):
    a=j*48+i;b=j*48+(i+1)%48;c=a+48;d=b+48;faces.extend([[a,b,c],[b,d,c]])
 else:
  # Irregular surfaces stay local: no whole-object convex shell or invented
  # backside. Extend only a small, supported quadratic tangent chart.
  n=fit['normal'];_,_,vh=np.linalg.svd(p-fit['center'],full_matrices=False);e=unit(vh[0]-n*(vh[0]@n));f=np.cross(n,e)
  q=np.stack([(p-fit['center'])@e,(p-fit['center'])@f],-1)
  try:hull=ConvexHull(q)
  except QhullError:return [],[]
  boundary=q[hull.vertices];origin=boundary.mean(0)
  # A concave/occluded patch must not be filled across its entire convex hull.
  # Planes may span their support; irregular patches require dense coverage.
  if kind=='local':
   area=hull.volume;spacing=np.median(np.linalg.norm(np.diff(q[:min(len(q),500)],axis=0),axis=1))
   if area>len(q)*spacing*spacing*3:return [],[]
  boundary=origin+(boundary-origin)*1.025
  samples=np.vstack([origin,boundary]);coords=p-fit['center'];height=coords@n
  design=np.stack([np.ones(len(q)),q[:,0],q[:,1],q[:,0]**2,q[:,0]*q[:,1],q[:,1]**2],-1)
  coefficients=np.linalg.lstsq(design,height,rcond=None)[0] if kind=='local' else np.zeros(6)
  if kind=='local':
   residual=np.quantile(abs(design@coefficients-height),.8)
   if residual>max(1e-6,np.linalg.norm(np.ptp(p,axis=0))*.02):return [],[]
  for x,y in samples:
   z=np.dot([1,x,y,x*x,x*y,y*y],coefficients);vertices.append(fit['center']+e*x+f*y+n*z)
  for i in range(len(boundary)):faces.append([0,1+i,1+(i+1)%len(boundary)])
 vertices=np.asarray(vertices);faces=np.asarray(faces,dtype=int)
 # Orient triangles consistently with the fitted outward normal field.
 for i,tri in enumerate(faces):
  c=vertices[tri].mean(0);n=np.cross(vertices[tri[1]]-vertices[tri[0]],vertices[tri[2]]-vertices[tri[0]])
  if kind=='sphere':expected=c-fit['center']
  elif kind=='cylinder':expected=c-fit['center']-fit['axis']*((c-fit['center'])@fit['axis'])
  else:expected=fit['normal']
  if n@expected<0:faces[i]=tri[::-1]
 return vertices.tolist(),faces.tolist()

def complete_objects(depth,normal,valid,fx,fy,planar_patches=(),barriers=None):
 h,w=depth.shape;n=normal/np.maximum(np.linalg.norm(normal,axis=-1,keepdims=True),1e-8)
 idx=np.arange(h*w).reshape(h,w);a=[];b=[]
 for dy,dx in [(0,1),(1,0)]:
  aa=idx[:h-dy,:w-dx];bb=idx[dy:,dx:]
  good=valid[:h-dy,:w-dx]&valid[dy:,dx:]&(np.abs(depth[:h-dy,:w-dx]-depth[dy:,dx:])<np.maximum(depth[:h-dy,:w-dx],1e-6)*.04)&(np.sum(n[:h-dy,:w-dx]*n[dy:,dx:],axis=-1)>.94)
  if barriers is not None:good &= ~barriers[0 if dx else 1]
  a.extend(aa[good]);b.extend(bb[good])
 graph=sparse.coo_matrix((np.ones(len(a),np.uint8),(a,b)),shape=(h*w,h*w)).tocsr()
 _,labels=connected_components(graph,directed=False);labels=labels.reshape(h,w)
 u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h);xyz=np.stack([(u-.5)/fx*depth,(v-.5)/fy*depth,depth],-1)
 groups=[];counts=np.bincount(labels[valid]);order=np.argsort(counts)[::-1]
 for patch in planar_patches:
  a,b,c,d=patch['boundsUV'];mean=unit(np.array(patch['normal']))
  selected=valid&(u>=a)&(u<=c)&(v>=b)&(v<=d)&((n@mean)>.985)
  p=xyz[selected]
  if len(p)<60:continue
  center=np.median(p,axis=0);scale=np.linalg.norm(np.ptp(p,axis=0))
  if np.quantile(abs((p-center)@mean),.8)>scale*.03:continue
  fit={'kind':'plane','center':center,'normal':mean,'error':0.}
  vertices,faces=surface_mesh(fit,p[::max(1,len(p)//1800)])
  if faces:groups.append({'kind':'plane','confidence':.75,'supportPixels':len(p),'fitError':0.,'vertices':vertices,'faces':faces,'inferred':True})
 for label in order[:80]:
  if counts[label]<80:break
  mask=valid&(labels==label);p=xyz[mask];nn=n[mask];stride=max(1,len(p)//1800);p=p[::stride];nn=nn[::stride]
  fit=fit_surface(p,nn);vertices,faces=surface_mesh(fit,p)
  if not faces:continue
  if any(not np.isfinite(vertex).all() or vertex[2]<=0 for vertex in np.asarray(vertices)):continue
  confidence=.8 if fit['kind'] in ('sphere','cylinder') else (.7 if fit['kind']=='plane' else .35)
  groups.append({'kind':fit['kind'],'confidence':confidence,'supportPixels':int(counts[label]),'fitError':fit['error'],
    'vertices':vertices,'faces':faces,'inferred':True})
 return groups
