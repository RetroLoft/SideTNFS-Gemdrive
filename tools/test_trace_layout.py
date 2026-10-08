#!/usr/bin/env python3
"""Execute the emitted 68000 copy/clear loops and check the dump ABI."""
import re,struct
from pathlib import Path
r=Path(__file__).resolve().parents[1]
b=(r/'dist/native/native.bin').read_bytes();listing=(r/'dist/native/native.lst').read_text()
def instruction(source):
 for line in listing.splitlines():
  if source in line and (m:=re.match(r'00:([0-9A-F]{8}) ',line)):
   return int(m[1],16)-0xfa0000
 raise AssertionError(source)
def u16(p):return struct.unpack_from('>H',b,p)[0]
start=b.index(b'SIDETNFSRECOV001');pc=instruction('move.w #HEADER_SIZE/2-1,d0');end=instruction('move.w d6,22(a3)')
allocation=instruction('move.l #TRACE_RAM_SIZE,-(sp)')
size=struct.unpack_from('>I',b,allocation+2)[0]
ram=bytearray([0xa5])*(size+16);a0=start;a1=0;steps=0;d0=0
while pc<end:
 steps+=1;assert steps<100000
 op=u16(pc);pc+=2
 if op==0x303c:d0=u16(pc);pc+=2
 elif op==0x32d8:ram[a1:a1+2]=b[a0:a0+2];a1+=2;a0+=2
 elif op==0x4299:ram[a1:a1+4]=bytes(4);a1+=4
 elif op==0x51c8:
  displacement=struct.unpack_from('>h',b,pc)[0];d0=(d0-1)&0xffff
  pc=pc+displacement if d0!=0xffff else pc+2
 else:raise AssertionError(hex(op))
assert a1==size and ram[size:]==bytes([0xa5])*16
assert ram[:64]==b[start:start+64]
assert ram[64:64+49152]==bytes(49152)
assert ram[64+49152:size]==b[start+64:a0]
assert ram[64+49152:64+49152+8]==b'XBRASTR1'
hook=64+49152+12
p=instruction('adda.l #TRACE_HANDLER_OFFSET,a2');assert struct.unpack_from('>I',b,p+2)[0]==hook
p=instruction('suba.l #TRACE_HANDLER_OFFSET,a3');assert struct.unpack_from('>I',b,p+2)[0]==hook
assert len(b)<20000
print(f'Trace ROM loops: {size} RAM bytes initialized, 49152 records bytes zeroed, ABI/hook offsets preserved, guard intact; ROM {len(b)} bytes')
