"""Explicit per-document wall-face constraint; independent of photo identity."""
import numpy as np
from scipy import ndimage

def constrain_wall(depth,normal,valid,fx,fy,mask):
 h,w=depth.shape;length=np.linalg.norm(normal,axis=-1);n=normal/np.maximum(length[...,None],1e-8)
 # Dominant upward-facing support gives the walkway/floor orientation.
 floor=valid&(np.abs(n[...,1])>.88)
 if floor.sum()<50:raise ValueError('No reliable floor orientation; select a photo with a visible support plane')
 up=np.median(n[floor],axis=0);up/=np.linalg.norm(up)
 selected=(mask>.5)&valid
 if selected.sum()<12:raise ValueError('Select a wall face with Surface or Outline first')
 horizontal=n[selected]-np.sum(n[selected]*up,-1,keepdims=True)*up
 horizontal/=np.maximum(1e-8,np.linalg.norm(horizontal,axis=-1,keepdims=True))
 mean=np.median(horizontal,axis=0);mean-=up*(mean@up);mean/=max(1e-8,np.linalg.norm(mean))
 if np.linalg.norm(mean)<.9:raise ValueError('Wall orientation is ambiguous; select one face at a time')
 u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h);rays=np.stack([(u-.5)/fx,(v-.5)/fy,np.ones_like(u)],-1)
 points=rays*depth[...,None]
 # Preserve the observed wall/floor contact, rather than tilting about its center.
 border=ndimage.binary_dilation(selected,iterations=2)&~selected&floor
 support=points[border] if border.sum()>=8 else points[selected]
 offset=float(np.median(support@mean));den=np.sum(rays*mean,-1)
 candidate=offset/np.where(abs(den)>1e-8,den,1e-8)
 ratio=candidate/np.maximum(depth,1e-8)
 safe=selected&(candidate>0)&(ratio>.35)&(ratio<2.8)
 if safe.sum()<selected.sum()*.7:raise ValueError('Wall fit is unstable; refine the face selection')
 out=depth.copy();out[safe]=candidate[safe]
 normals=normal.copy();normals[safe]=mean
 return out,normals,{'constrainedPixels':int(safe.sum()),'floorNormal':up.tolist(),'wallNormal':mean.tolist(),'perpendicularDot':float(abs(mean@up))}
