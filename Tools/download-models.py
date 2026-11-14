"""Download pinned public model files using the official hf CLI."""
from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parent.parent
for model in json.loads((root/'Tools/models.lock.json').read_text()):
    destination=root/model['destination'];destination.mkdir(parents=True,exist_ok=True)
    command=['hf','download',model['repository'],'--revision',model['revision'],'--local-dir',str(destination),'--include',*model['include']]
    subprocess.run(command,check=True)
    if 'sha256' in model:
        digest=hashlib.sha256()
        with (destination/'model.onnx').open('rb') as stream:
            for block in iter(lambda:stream.read(4*1024*1024),b''):digest.update(block)
        if digest.hexdigest()!=model['sha256']:raise RuntimeError('Model checksum mismatch: '+model['repository'])
