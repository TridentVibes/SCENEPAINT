"""Camera-consistent normal integration with anchored depth and silhouette barriers."""
import numpy as np
from scipy.sparse import coo_matrix,diags
from scipy.sparse.linalg import cg

def refine(depth,normal,valid,fx,fy,prior=None,barriers=None):
 h,w=depth.shape;z=np.maximum(depth,1e-6);base=np.log(z).astype(np.float64)
 prior_used=False
 if prior is not None:
  x=prior.ravel();y=(1/z).ravel();ok=valid.ravel() & np.isfinite(x)
  A=np.stack([x,np.ones_like(x)],-1);coef=np.linalg.lstsq(A[ok][::4],y[ok][::4],rcond=None)[0]
  for _ in range(4):
   err=np.abs(A@coef-y);keep=ok&(err<np.quantile(err[ok],.7));coef=np.linalg.lstsq(A[keep][::4],y[keep][::4],rcond=None)[0]
  predicted=(A@coef).reshape(h,w)
  if coef[0]>0 and np.corrcoef(x[ok],y[ok])[0,1]>.8:
   candidate=1/np.maximum(predicted,1e-6)
   confidence=valid&(predicted>0)&(np.abs(np.log(candidate/z))<.5)
   base[confidence]=.7*base[confidence]+.3*np.log(candidate[confidence]);prior_used=True
 u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h)
 rays=np.stack([(u-.5)/fx,(v-.5)/fy,np.ones_like(u)],-1)
 n=normal/np.maximum(1e-8,np.linalg.norm(normal,axis=-1,keepdims=True));den=np.sum(n*rays,-1)
 safe=np.where(np.abs(den)>.15,den,np.where(den<0,-.15,.15))
 gx=np.clip(-n[...,0]/(fx*w*safe),-.08,.08);gy=np.clip(-n[...,1]/(fy*h*safe),-.08,.08)
 confidence=np.clip((np.abs(den)-.15)/.6,0,1)*valid
 index=np.arange(w*h).reshape(h,w);left=[];right=[];targets=[];weights=[]
 for axis,gradient in [(1,gx),(0,gy)]:
  a=(slice(None),slice(None,-1)) if axis==1 else (slice(None,-1),slice(None))
  b=(slice(None),slice(1,None)) if axis==1 else (slice(1,None),slice(None))
  crease=np.sum(n[a]*n[b],axis=-1)>.94
  if barriers is not None:crease &= ~barriers[0 if axis==1 else 1]
  connected=crease&valid[a]&valid[b]&(np.abs(z[a]-z[b])<np.minimum(z[a],z[b])*.06)
  weight=np.minimum(confidence[a],confidence[b])[connected]
  old=(base[b]-base[a])[connected];pred=((gradient[a]+gradient[b])*.5)[connected]
  left.append(index[a][connected]);right.append(index[b][connected]);targets.append(.8*pred+.2*old);weights.append(weight)
 i=np.concatenate(left);j=np.concatenate(right);g=np.concatenate(targets);weight=np.concatenate(weights)
 size=w*h;anchor=.001
 degree=np.bincount(i,weight,minlength=size)+np.bincount(j,weight,minlength=size)+anchor
 matrix=diags(degree)+coo_matrix((np.concatenate([-weight,-weight]),(np.concatenate([i,j]),np.concatenate([j,i]))),shape=(size,size)).tocsr()
 rhs=anchor*base.ravel()+np.bincount(j,weight*g,minlength=size)-np.bincount(i,weight*g,minlength=size)
 solved,info=cg(matrix,rhs,x0=base.ravel(),M=diags(1/degree),rtol=1e-4,maxiter=240)
 output=np.exp(np.clip(solved.reshape(h,w),base-.22,base+.22));output[~valid]=0
 before=np.mean(np.abs((np.log(z).ravel()[j]-np.log(z).ravel()[i])-g)*weight)
 after=np.mean(np.abs((np.log(np.maximum(output,1e-6)).ravel()[j]-np.log(np.maximum(output,1e-6)).ravel()[i])-g)*weight)
 from planes import preserve_planes
 output,planar=preserve_planes(output,n,valid,fx,fy,barriers)
 return output.astype(np.float32),{**planar,'normalGradientErrorBefore':float(before),'normalGradientErrorAfter':float(after),'depthPriorAligned':prior_used,'solverStatus':int(info)}
