/* Exercise the real PRG loader: protection flags must not affect relocation,
 * BSS clearing, FASTLOAD heap policy, or rejection before allocation. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "program_loader.h"
static uint8_t image[49], memory[2048];
static unsigned allocations, releases, flushes;
static int32_t read_image(void *ctx,uint32_t off,uint8_t *out,uint32_t n){
 (void)ctx;if(off>sizeof(image) || n>sizeof(image)-off)return -66;
 memcpy(out,image+off,n);return (int32_t)n;
}
static int32_t create(void *ctx,uint32_t tail,uint32_t env){
 (void)ctx;assert(tail==123 && env==456);allocations++;
 memset(memory,0xa5,sizeof(memory));exput(memory+4,0x10000+sizeof(memory));return 0x10000;
}
static uint8_t *pointer(void *ctx,uint32_t addr){
 (void)ctx;assert(addr>=0x10000 && addr<0x10000+sizeof(memory));return memory+addr-0x10000;
}
static void release(void *ctx,uint32_t bp){(void)ctx;assert(bp==0x10000);releases++;}
static void cache(void *ctx){(void)ctx;flushes++;}
static void fixture(uint32_t flags){
 memset(image,0,sizeof(image));image[0]=0x60;image[1]=0x1a;
 exput(image+2,12);exput(image+6,4);exput(image+10,8);
 exput(image+18,0x4d694e54);exput(image+22,flags);
 exput(image+32,12);exput(image+44,4); /* relocate TEXT+4; terminator at 48 */
 allocations=releases=flushes=0;
}
int main(void){
 r07_io io={NULL,read_image,create,pointer,release,cache};
 for(unsigned mode=0;mode<4;mode++)for(unsigned low=0;low<8;low++){
  fixture((mode<<4)|low);
  assert(r07_load(&io,sizeof(image),123,456)==0x10000);
  assert(allocations==1 && releases==0 && flushes==1);
  assert(ex32(memory+260)==0x1010c);
  assert(ex32(memory+8)==0x10100 && ex32(memory+12)==12);
  assert(ex32(memory+16)==0x1010c && ex32(memory+20)==4);
  assert(ex32(memory+24)==0x10110 && ex32(memory+28)==8);
  for(unsigned i=272;i<280;i++)assert(memory[i]==0);
  for(unsigned i=280;i<sizeof(memory);i++)assert(memory[i]==((low&1)?0xa5:0));
 }
 /* Includes undefined protection modes, library and shared-text flags. */
 for(unsigned mode=4;mode<16;mode++){
  fixture((mode<<4)|7);assert(r07_load(&io,sizeof(image),123,456)==-66);assert(!allocations && !flushes);
 }
 for(unsigned bit=0;bit<32;bit++)if(bit==3 || bit>=8){
  fixture(0x17u|(1u<<bit));assert(r07_load(&io,sizeof(image),123,456)==-66);assert(!allocations && !flushes);
 }
 fixture(0x17);exput(image+44,15);assert(r07_load(&io,sizeof(image),123,456)==-66);assert(allocations==1 && releases==1 && !flushes);
 fixture(0x17);assert(r07_load(&io,sizeof(image)-1,123,456)==-66);assert(allocations==1 && releases==1 && !flushes);
 puts("PRG flags: all 32 supported combinations, HighWire 0x17, relocation, BSS/heap clearing and invalid flags/relocations passed.");
 return 0;
}
