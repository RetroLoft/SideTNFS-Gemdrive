/* Checked GEMDOS PRG loader. Adapters own read-only input and native memory.
 * Returns a PE_LOAD basepage or a negative GEMDOS error. No execution here. */
#include <stdint.h>
#include <stddef.h>
typedef struct {
 void *context;
 int32_t (*read)(void *,uint32_t,uint8_t *,uint32_t);
 int32_t (*create)(void *,uint32_t,uint32_t);
 uint8_t *(*pointer)(void *,uint32_t);
 void (*release)(void *,uint32_t);
 void (*cache)(void *);
} r07_io;
static uint16_t ex16(const uint8_t *p){return (uint16_t)((p[0]<<8)|p[1]);}
static uint32_t ex32(const uint8_t *p){return ((uint32_t)ex16(p)<<16)|ex16(p+2);}
static void exput(uint8_t *p,uint32_t n){p[0]=n>>24;p[1]=n>>16;p[2]=n>>8;p[3]=n;}
static int32_t exread(r07_io *io,uint32_t off,uint8_t *p,uint32_t n){int32_t r=io->read(io->context,off,p,n);return r<0?r:(uint32_t)r==n?0:-66;}
static int32_t r07_load(r07_io *io,uint32_t size,uint32_t tail,uint32_t env){
 /* MiNT toolchain stamp occupies the reserved TOS header long; the
  * supplied utility retains the ordinary TOS entry and relocation format. */
 uint8_t h[28],rel[508];int32_t error=exread(io,0,h,28);if(error)return error;
 if(ex16(h)!=0x601a || !ex32(h+2) || (ex32(h+18) && ex32(h+18)!=0x4d694e54u))return -66;
 /* Bits 4..7 are the documented MiNT protection mode: private (0),
  * global (1), supervisor (2), read-only (3). Plain TOS has no memory
  * protection, so accept these as metadata without changing allocation.
  * Reject undefined modes, shared-library/text and all other high flags. */
 uint32_t flags=ex32(h+22);
 if((flags&~0xf7u) || ((flags>>4)&15u)>3u)return -66;
 uint32_t text=ex32(h+2),data=ex32(h+6),bss=ex32(h+10),symbols=ex32(h+14);
 if(text>0x7ffff000u || data>0x7ffff000u-text)return -66;
 uint32_t td=text+data;if(bss>0x7ffff000u-td)return -66;
 if(size<28 || td>size-28 || symbols>size-28-td)return -66;
 uint32_t reloc=28+td+symbols;
 if(!ex16(h+26) && size-reloc<4)return -66;
 int32_t made=io->create(io->context,tail,env);if(made<=0)return made<0?made:-39;
 uint32_t bp=(uint32_t)made;uint8_t *base=io->pointer(io->context,bp);
 uint32_t high=ex32(base+4);
 if(high<bp || high-bp<512 || td+bss>high-bp-512){error=-39;goto fail;}
 uint32_t start=bp+256;uint8_t *body=io->pointer(io->context,start);
 error=exread(io,28,body,td);if(error)goto fail;
 if(!ex16(h+26)){
  error=exread(io,reloc,rel,4);if(error)goto fail;reloc+=4;
  uint32_t at=ex32(rel),cached=0,index=0;
  if(at){
   for(;;){
    if((at&1) || td<4 || at>td-4){error=-66;goto fail;}
    uint32_t value=ex32(body+at);if(value>0xffffffffu-start){error=-66;goto fail;}
    exput(body+at,value+start);
    for(;;){
     if(index==cached){cached=size-reloc;if(cached>sizeof(rel))cached=sizeof(rel);if(!cached){error=-66;goto fail;}
      error=exread(io,reloc,rel,cached);if(error)goto fail;reloc+=cached;index=0;}
     unsigned delta=rel[index++];if(!delta)goto relocated;
     uint32_t step=delta==1?254:delta;
     if(at>0xffffffffu-step){error=-66;goto fail;}at+=step;
     if(delta!=1)break;
    }
   }
  }
 }
relocated:;
 /* FASTLOAD skips clearing the unused heap; BSS is always cleared.
  * Flags 2/4 are accepted as placement/allocation preferences, using
  * the existing native ST-RAM allocation policy in this recovery stage.
  * Do not propagate alternate-RAM or protection policy to native TOS. */
 uint32_t clear_end=(flags&1u)?td+bss:high-start;
 for(uint32_t i=td;i<clear_end;i++)body[i]=0;
 exput(base+8,start);exput(base+12,text);exput(base+16,start+text);exput(base+20,data);
 exput(base+24,start+td);exput(base+28,bss);
 io->cache(io->context);return made;
fail:
 io->release(io->context,bp);return error;
}
