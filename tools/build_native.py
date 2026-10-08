#!/usr/bin/env python3
"""Build native cartridge GEMDRIVE from local sources with an offline toolchain."""
import os,io,json,hashlib,struct,subprocess,tarfile
from pathlib import Path
IMAGE = os.environ.get("SIDETNFS_TOOLCHAIN_IMAGE", "304fea9c3e8e")  # cached local compiler; never pulled
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'src/native'
entries={p.name:p.read_bytes() for p in SOURCE.iterdir() if p.suffix in ('.c','.h','.s')}
entries['native.s']=entries.pop('boot.s')
# The container creates size constants from the linked executable, then
# assembles the cartridge. The host independently checks every relocation.
entries['layout.py']=b'''import struct
p=open("resident.tos","rb").read()
t,d,b,s=struct.unpack_from(">4I",p,2)
assert p[:2]==b"\\x60\\x1a" and (t+d)%2==0 and 0<t+d<65536 and 0<b<=65536
open("resident.inc","w").write("R05_COPY equ %d\\nR05_BSS equ %d\\nR05_MEMORY equ %d\\nR05_RELOC equ %d\\n"%(t+d,b,t+d+b,28+t+d+s))
'''
stream=io.BytesIO()
with tarfile.open(fileobj=stream,mode='w') as tf:
 for name,b in entries.items():
  info=tarfile.TarInfo(name);info.size=len(b);tf.addfile(info,io.BytesIO(b))
cmd='''cd /buildsrc
tar xf -
mkdir dist
vasm -Faout -quiet -m68000 -spaces -devpac entry.s -o entry.o >&2
m68k-atari-mint-gcc -m68000 -std=c99 -Os -ffreestanding -fno-builtin -fno-stack-protector -Wall -Wextra -Werror -c driver.c -o driver.o >&2
m68k-atari-mint-gcc -m68000 -std=c99 -Os -ffreestanding -fno-builtin -fno-stack-protector -Wall -Wextra -Werror -c transport.c -o transport.o >&2
vlink -s -bataritos entry.o driver.o transport.o -o resident.tos >&2
python3 layout.py
vasm -Fbin -quiet -m68000 -spaces -devpac -DRECOVERY_HOOK=1 -L dist/native.lst native.s -o dist/native.bin >&2
cp resident.tos resident.inc dist/
tar cf - dist
'''
r=subprocess.run(['docker','run','--rm','--pull=never','--network=none','--read-only','--tmpfs','/buildsrc:rw,exec','--tmpfs','/tmp:rw,exec','-i','--entrypoint','sh',IMAGE,'-ec',cmd],input=stream.getvalue(),stdout=subprocess.PIPE,check=True)
dest=ROOT/'dist/native';dest.mkdir(parents=True,exist_ok=True);outputs={}
with tarfile.open(fileobj=io.BytesIO(r.stdout),mode='r:') as tf:
 for member in tf.getmembers():
  if not member.isfile():continue
  p=Path(member.name);assert p.parent==Path('dist')
  b=tf.extractfile(member).read();(dest/p.name).write_bytes(b);outputs[p.name]={'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
p=(dest/'resident.tos').read_bytes();t,d,b,s=struct.unpack_from('>4I',p,2)
assert struct.unpack_from('>H',p,26)[0]==0
pos=28+t+d+s;target=struct.unpack_from('>I',p,pos)[0];assert target
addresses=[target]
for delta in p[pos+4:]:
 if not delta:break
 target+=254 if delta==1 else delta
 if delta!=1:addresses.append(target)
else:raise AssertionError('Unterminated relocations')
assert all(a%2==0 and a+4<=t+d for a in addresses)
assert all(struct.unpack_from('>I',p,28+a)[0]<t+d+b for a in addresses)
rom=(dest/'native.bin').read_bytes();assert len(rom)<=65536 and len(rom)%2==0 and rom.count(p)==1
manifest={'toolchain_image':IMAGE,'files':outputs,'resident':{'copy_bytes':t+d,'bss_bytes':b,'relocations':len(addresses)},'source_sha256':{name:hashlib.sha256(blob).hexdigest() for name,blob in entries.items()}}
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest['resident']));print('ROM bytes:',len(rom))

subprocess.run(["python3",str(ROOT/"tools/test_trace_layout.py")],check=True)
