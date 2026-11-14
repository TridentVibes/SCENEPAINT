"""Fetch the official pinned standalone Python archive for binary packaging."""
from pathlib import Path
import hashlib,json,tarfile,urllib.request
root=Path(__file__).resolve().parent.parent
metadata=json.loads((root/'Packaging/PythonStandalone/PROVENANCE.json').read_text())
cache=root/'Cache';cache.mkdir(exist_ok=True)
archive=cache/'python-standalone.tar.gz'
if not archive.exists():
    with urllib.request.urlopen(metadata['url']) as response,archive.open('wb') as output:
        while block:=response.read(1024*1024):output.write(block)
hash=hashlib.sha256()
with archive.open('rb') as stream:
    while block:=stream.read(1024*1024):hash.update(block)
if hash.hexdigest()!=metadata['sha256']:raise RuntimeError('Standalone Python checksum mismatch; remove the cached archive and retry')
target=root/'Packaging/PythonStandalone'
if (target/'python').exists():raise RuntimeError('Standalone runtime already exists; leave it in place or move it before reinstalling')
with tarfile.open(archive) as bundle:bundle.extractall(target,filter='data')
print('Pinned standalone runtime extracted; license files are preserved.')
