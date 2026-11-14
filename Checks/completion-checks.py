import sys,numpy as np
sys.path.insert(0,'Geometry')
from object_completion import fit_surface,surface_mesh,complete_objects
from completion import complete_walls,wall_groups
rng=np.random.default_rng(7)
# Front hemisphere with real outward normals must recover a sphere and backside.
a=rng.uniform(0,2*np.pi,1200);z=rng.uniform(-1,-.15,1200);r=np.sqrt(1-z*z);n=np.stack([r*np.cos(a),r*np.sin(a),z],-1);p=n*.6+[0,0,4]
f=fit_surface(p,n);assert f['kind']=='sphere',f
v,t=surface_mesh(f,p);v=np.array(v);assert v[:,2].max()>4.5
assert abs(f['radius']-.6)<1e-5
# Pole/cylinder with only a visible arc; it must remain convex and not cave inward.
a=rng.uniform(np.pi*1.1,np.pi*1.9,1200);y=rng.uniform(-1,1,1200);n=np.stack([np.cos(a),np.zeros_like(a),np.sin(a)],-1);p=n*.3+np.stack([np.zeros_like(y),y,np.full_like(y,3)],-1)
f=fit_surface(p,n);assert f['kind']=='cylinder',f
v,t=surface_mesh(f,p);v=np.array(v);assert v[:,2].max()>3.29
assert abs(f['radius']-.3)<1e-5
# Oriented plane remains a bounded patch; it gains no arbitrary closed backside.
p=np.column_stack([rng.uniform(-1,1,300),rng.uniform(-1,1,300),np.full(300,4.)]);n=np.tile([0,0,-1.],(300,1));f=fit_surface(p,n);assert f['kind']=='plane'
v,t=surface_mesh(f,p);assert np.max(abs(np.array(v)[:,2]-4))<1e-8
# A highly irregular cloud must not be mislabeled a sphere or cylinder.
p=rng.uniform(-1,1,(500,3))+[0,0,4];n=rng.normal(size=(500,3));n/=np.linalg.norm(n,axis=1,keepdims=True)
assert fit_surface(p,n)['kind']=='local'
# Missing/invalid data is excluded and inputs never mutate.
d=np.full((40,40),3.,np.float32);n=np.zeros((40,40,3));n[...,2]=-1;valid=np.ones((40,40),bool);valid[15:25,15:25]=False
original=d.copy();g=complete_objects(d,n,valid,1,1);assert np.array_equal(original,d);assert g
assert all(np.isfinite(x['vertices']).all() for x in g)
print('PASS: sphere backside, cylinder backside, bounded plane, irregular rejection, invalid exclusion, immutable observations')
