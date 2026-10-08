"""Compile the untouched upstream ST release path in an offline container."""
from pathlib import Path
import io,tarfile,subprocess
r=Path(__file__).resolve().parents[1];buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w') as t:
 for n in ['Makefile','Makefile.release','version.txt','src']:
  t.add(r/n,arcname=n)
subprocess.run(['docker','run','--rm','--pull=never','--network=none','--read-only','--tmpfs','/buildsrc:rw,exec','--tmpfs','/tmp:rw,exec','-i','--entrypoint','sh','304fea9c3e8e','-ec','cd /buildsrc; tar xf -; make all DEBUG_MODE=0 RELEASE_MODE=1'],input=buf.getvalue(),check=True)
