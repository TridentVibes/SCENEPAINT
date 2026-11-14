#!/usr/bin/env python3
"""Build the public artifact from an explicit allowlist, with relocated Python."""
from pathlib import Path
import os,shutil,subprocess,stat,json,hashlib,datetime
ROOT=Path(__file__).resolve().parent.parent
DIST=ROOT/'Releases'/'ScenePaint-0.2-macOS-AppleSilicon'
APP=DIST/'ScenePaint.app'
PAYLOAD=APP/'Contents/Resources/ScenePaint'
TOOLS=Path(os.environ.get('DEVELOPER_DIR') or subprocess.check_output(['/usr/bin/xcode-select','-p'],text=True).strip())/'usr/bin'
def run(*args):subprocess.run([str(x) for x in args],check=True,stdout=subprocess.DEVNULL)
def copytree(src,dst):shutil.copytree(src,dst,symlinks=False,ignore=shutil.ignore_patterns('__pycache__','.DS_Store','.cache','*.pyc'))
if DIST.exists():
 old=DIST.with_name(DIST.name+'-previous-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
 DIST.rename(old)
DIST.mkdir(parents=True)
copytree(ROOT/'Build/Release/ScenePaint.app',APP)
PAYLOAD.mkdir(parents=True)
for model in ['DepthAnythingV2SmallF16.mlmodelc','SAM2','SAM2BasePlus']:
 if model in ['SAM2','SAM2BasePlus']:
  target=PAYLOAD/'Models'/model;target.mkdir(parents=True)
  for item in (ROOT/'Models'/model).glob('*.mlmodelc'):
   if model=='SAM2' and 'ImageEncoder' in item.name:continue # Legacy archives need prompt/mask decoding only.
   copytree(item,target/item.name)
 else:copytree(ROOT/'Models'/model,PAYLOAD/'Models'/model)
(PAYLOAD/'Models/MoGe2Base').mkdir(parents=True)
shutil.copy2(ROOT/'Models/MoGe2Base/model.onnx',PAYLOAD/'Models/MoGe2Base/model.onnx')
copytree(ROOT/'Geometry',PAYLOAD/'Geometry')
demo=ROOT/'Packaging/PublicDemo/Pumpkin Motion.scenepaint'
if demo.exists():copytree(demo,PAYLOAD/'Demo/Pumpkin Motion.scenepaint')
RUNTIME=PAYLOAD/'Runtime'
base=ROOT/'Packaging/PythonStandalone/python'
copytree(base,RUNTIME/'Python')
STDLIB=RUNTIME/'Python/lib/python3.12'
for pattern in ['site-packages','test','tests','tkinter','idlelib','ensurepip','turtledemo']:
 item=STDLIB/pattern
 if item.is_dir():shutil.rmtree(item)
for item in STDLIB.glob('config-*'):
 if item.is_dir():shutil.rmtree(item)
for pattern in ['readline*','_gdbm*','_curses*','_tkinter*']:
 for item in (STDLIB/'lib-dynload').glob(pattern):item.unlink()
SITE=RUNTIME/'Geometry/lib/python3.12/site-packages'
copytree(ROOT/'Runtime/Geometry/lib/python3.12/site-packages',SITE)
for pattern in ['pip','pip-*','setuptools','setuptools-*','wheel','wheel-*','_distutils_hack','distutils-precedence.pth']:
 for item in SITE.glob(pattern):
  if item.is_dir():shutil.rmtree(item)
  else:item.unlink()
(RUNTIME/'Geometry/bin').mkdir(parents=True)
launcher=RUNTIME/'Geometry/bin/python'
launcher.write_text('''#!/bin/sh
SCENE_RUNTIME="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
export PYTHONHOME="$SCENE_RUNTIME/Python"
export PYTHONPATH="$SCENE_RUNTIME/Geometry/lib/python3.12/site-packages"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
exec "$SCENE_RUNTIME/Python/bin/python3.12" "$@"
''');launcher.chmod(0o755)
# Resolve every non-system Mach-O dependency recursively and rewrite load paths.
LIBS=RUNTIME/'Libraries';LIBS.mkdir()
def macho(p):
 try:
  if not p.is_file():return False
  with p.open('rb') as f:magic=f.read(4)
  return magic in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']
 except OSError:return False
queue=[p for p in RUNTIME.rglob('*') if macho(p)];seen=set();external_sources=set()
while queue:
 owner=queue.pop()
 if owner in seen:continue
 seen.add(owner);owner.chmod(owner.stat().st_mode|stat.S_IWUSR)
 result=subprocess.check_output([str(TOOLS/'otool'),'-L',str(owner)],text=True)
 changes=[]
 for line in result.splitlines()[1:]:
  dep=line.strip().split(' (',1)[0]
  if dep.startswith('/opt/homebrew/'):
   external_sources.add(Path(dep).resolve())
   if 'Python.framework/' in dep and dep.endswith('/Python'):target=RUNTIME/'Python/Python'
   else:
    target=LIBS/Path(dep).name
    if not target.exists():shutil.copy2(dep,target);queue.append(target)
   relative='@loader_path/'+os.path.relpath(target,owner.parent)
   changes+=['-change',dep,relative]
 if changes:run(TOOLS/'install_name_tool',*changes,owner)
 # Remove the absolute library install ID where applicable.
 if owner in LIBS.iterdir():run(TOOLS/'install_name_tool','-id','@loader_path/'+owner.name,owner)
# Embed the icon and register project packages with Finder.
if (ROOT/'Branding/ScenePaint.icns').exists():shutil.copy2(ROOT/'Branding/ScenePaint.icns',APP/'Contents/Resources/ScenePaint.icns')
import plistlib
plist_path=APP/'Contents/Info.plist';plist=plistlib.loads(plist_path.read_bytes())
plist.update(CFBundleName='ScenePaint',CFBundleDisplayName='ScenePaint',CFBundleShortVersionString='0.2',CFBundleVersion='2',NSHumanReadableCopyright='ScenePaint 0.2. Third-party notices included.')
assert plist['ScenePaintRelease'] is True
assert plist['UTExportedTypeDeclarations'][0]['UTTypeTagSpecification']['public.filename-extension']==['scenepaint']
# Keep the build's tested .scenepaint document registration.
plist_path.write_bytes(plistlib.dumps(plist))
NOTICES=DIST/'Third-party notices';NOTICES.mkdir()
shutil.copy2(ROOT/'Geometry/MoGe-LICENSE.txt',NOTICES/'MoGe-LICENSE.txt')
shutil.copy2(ROOT/'Packaging/THIRD-PARTY.md',NOTICES/'README.md')
for source in (ROOT/'Packaging').glob('*LICENSE*.txt'):shutil.copy2(source,NOTICES/source.name)
shutil.copy2(ROOT/'Packaging/Apache-2.0.txt',NOTICES/'Apache-2.0.txt')
copytree(ROOT/'Packaging/RuntimeLicenses',NOTICES/'Python-runtime-components')
# Preserve installed package licenses and metadata; additionally collect licenses
# for the Python interpreter and vendored system libraries.
for source in list(base.glob('*LICENSE*'))+list(base.glob('licenses/**/*'))+list(base.glob('share/licenses/**/*')):
 if source.is_file() and source.stat().st_size<500_000:shutil.copy2(source,NOTICES/('Python-'+source.name))
for source in external_sources:
 parts=source.parts
 if 'Cellar' not in parts:continue
 idx=parts.index('Cellar');formula=parts[idx+1];cellar=Path(*parts[:idx+3])
 for license in list(cellar.glob('**/*LICENSE*'))+list(cellar.glob('**/*COPYING*')):
  if license.is_file() and license.stat().st_size<500_000:
   target=NOTICES/(formula+'-'+license.name)
   if not target.exists():shutil.copy2(license,target)
for source in [ROOT/'Packaging/README.txt',ROOT/'Packaging/RELEASE-NOTES.md']:
 shutil.copy2(source,DIST/source.name)
copytree(NOTICES,APP/'Contents/Resources/Third-party notices')
shutil.copy2(ROOT/'Packaging/README.txt',APP/'Contents/Resources/ScenePaint Tips.txt')
shutil.copy2(ROOT/'LICENSE',DIST/'LICENSE')
shutil.copy2(ROOT/'NOTICE.md',DIST/'NOTICE.md')
shutil.copy2(ROOT/'LICENSE',APP/'Contents/Resources/ScenePaint Code License.txt')
shutil.copy2(ROOT/'NOTICE.md',APP/'Contents/Resources/ScenePaint Code Notice.md')
# Strip Finder comments, quarantine and other creator-machine extended attributes.
run('/usr/bin/xattr','-cr',DIST)
# Sign inner native libraries after relocation, then seal the outer application.
for path in sorted(seen,key=lambda p:len(str(p)),reverse=True):run('/usr/bin/codesign','--force','--sign','-',path)
run('/usr/bin/codesign','--force','--deep','--sign','-',APP)
run('/usr/bin/codesign','--verify','--deep','--strict',APP)
# A release must never depend on Homebrew or include unapproved personal material.
for path in seen:
 deps=subprocess.check_output([str(TOOLS/'otool'),'-L',str(path)],text=True)
 assert '\t/opt/homebrew/' not in deps,(path,deps)
assert not any((PAYLOAD/p).exists() for p in ['Assets','Analysis','Projects','Backups','Cache','Settings.json'])
if demo.exists():assert (PAYLOAD/'Demo/Pumpkin Motion.scenepaint/document.json').exists()
# Record actual binary deployment targets rather than assuming the SDK target.
import re
minimum=(14,0)
for path in seen:
 load=subprocess.check_output([str(TOOLS/'otool'),'-l',str(path)],text=True)
 for value in re.findall(r'\bminos\s+([0-9.]+)',load):
  version=tuple(map(int,value.split('.')))
  minimum=max(minimum,version)
assert minimum<=(14,0),("Runtime exceeds the advertised minimum OS",minimum)
(DIST/'BUILD-INFO.json').write_text(json.dumps({'version':'0.2','architecture':'arm64','minimumMacOS':'14.0','signing':'ad-hoc; not notarized','projectExtension':'.scenepaint','startup':'Motion demo; paused' if demo.exists() else 'Blank project','models':['Depth Anything V2 Small F16','SAM 2.1 BasePlus F16','SAM 2.1 Tiny prompt/mask decoders for legacy archives','MoGe-2 Base normal ONNX'],'python':json.loads((ROOT/'Packaging/PythonStandalone/PROVENANCE.json').read_text())},indent=2))
print(DIST,flush=True)
