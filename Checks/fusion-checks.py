"""Fast evidence-alignment and reconstruction-boundary regression checks."""
import json,sys,tempfile
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0,'Geometry')
from fusion import load_evidence,boundaries,region_labels
from refine import refine
rng=np.random.default_rng(2);w=h=48
rgb=rng.integers(0,256,(h,w,3),np.uint8);photo=Image.fromarray(rgb)
scene={'width':w,'height':h,'rgb':rgb.ravel().tolist(),'depth':np.tile(np.linspace(0,1,w),(h,1)).ravel().tolist(),'segmentationAvailable':False}
with tempfile.TemporaryDirectory(dir='Temporary') as folder:
 path=Path(folder)/'scene.json';path.write_text(json.dumps(scene));mask=Path(folder)/'mask';m=np.zeros((h,w),np.uint8);m[:,:24]=255;mask.write_bytes(m.tobytes())
 e,a=load_evidence(photo,path,(w,h),[mask]);assert a['alignmentMeanError']==0 and len(e['masks'])==1
 try:load_evidence(photo.transpose(Image.Transpose.FLIP_TOP_BOTTOM),path,(w,h));raise AssertionError('Wrong orientation accepted')
 except ValueError:pass
 mask.write_bytes(b'bad')
 try:load_evidence(photo,path,(w,h),[mask]);raise AssertionError('Bad mask dimensions accepted')
 except ValueError:pass
 z=np.full((h,w),3.);n=np.zeros((h,w,3));n[...,2]=-1;valid=np.ones((h,w),bool)
 e['masks']=[];e['rgb']=np.where(np.arange(w)[None,:,None]<24,0,255).astype(np.uint8)*np.ones((h,1,3),np.uint8)
 b=boundaries(z,n,valid,e);assert not b[0].any() and not b[1].any(),'Color alone must not produce a geometric edge'
 e['masks']=[m>127];b=boundaries(z,n,valid,e);assert b[0][:,23].all()
 labels=region_labels(valid,b);assert labels[20,20]!=labels[20,30]
 z[:,24:]=3.1;before=z.copy();out,info=refine(z,n,valid,1,1,barriers=b)
 assert np.isfinite(out).all() and np.array_equal(z,before)
 assert abs(float(np.median(out[:,:24]))-3)<.03 and abs(float(np.median(out[:,24:]))-3.1)<.03
print('PASS: photo orientation, map dimensions, color-edge restraint, surface boundaries, finite fusion, immutable evidence')
