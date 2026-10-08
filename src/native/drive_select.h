/* F27: Falcon TOS 4.04 extended current-drive compatibility.
 * Native selection runs first, with fallback only for mounted owned drives.
 * S27CHECK hardware evidence shows p_curdrv is a WORD at PD+56, followed
 * by p_uftsize at +58 and p_uft at +60. The byte-at-55 layout from tos3x
 * used in F26 does NOT describe this Falcon's process record.
 * Limit this private-layout workaround to 4.04; validate both bytes against
 * native Dgetdrv. Preserve native process inheritance/restoration by using
 * the real PD. No global override, instruction patch or process shadow map.
 * Unknown versions, alternative kernels and TT-RAM PDs fail closed.
 */
#ifndef R26_MEMORY
#define R26_MEMORY(n) ((volatile uint8_t *)(uintptr_t)(n))
#endif
static uint32_t r26_long(uint32_t address){
    volatile uint8_t *p=R26_MEMORY(address);
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}
static int r26_ram(uint32_t p,unsigned n,uint32_t top){
    return !(p&1) && p>=0x800 && top>=n && p<=top-n;
}
static int r26_set_current(unsigned d){
    uint32_t top=r26_long(0x42e),os=r26_long(0x4f2);
    if(top<0x1000 || top>0xe00000 || (os&1) ||
       !((os>=0xe00000 && os<=0xe7ffd0) || r26_ram(os,48,top)))return 0;
    volatile uint8_t *h=R26_MEMORY(os);
    unsigned version=((unsigned)h[2]<<8)|h[3];
    if(version!=0x0404)return 0;
    uint32_t jar=r26_long(0x5a0);
    if(jar){
        unsigned i;
        for(i=0;i<128;i++,jar+=8){
            if(!r26_ram(jar,8,top))return 0;
            uint32_t key=r26_long(jar);
            if(!key)break;
            if(key==0x4d694e54u || key==0x4d616758u)return 0; /* MiNT/MagX */
        }
        if(i==128)return 0;
    }
    uint32_t run=r26_long(os+40);
    if(!r26_ram(run,4,top))return 0;
    uint32_t bp=r26_long(run);
    if(!r26_ram(bp,256,top) || r26_long(bp)!=bp)return 0;
    uint32_t end=r26_long(bp+4);
    if(end<bp+256 || end>top)return 0;
    volatile uint8_t *pd=R26_MEMORY(bp);
    unsigned old=r03_native_drive();
    if(old>=26 || pd[56]!=0 || pd[57]!=old)return 0;
    /* The checked high byte is zero; change only the low byte of the word. */
    pd[57]=(uint8_t)d;
    if(r03_native_drive()==d)return 1;
    pd[57]=(uint8_t)old;return 0;
}
static int32_t r26_select_drive(const uint8_t *a){
    unsigned d=be16(a+2),owned=0;
    for(unsigned i=0;i<11;i++)
        if(d==drive_numbers[i] && (i==0 || (i==1?settings_active:drive_active[i])))owned=1;
    if(d<16 || d>=26 || !owned || !(r03_drive_bits()&(1u<<d)))return PASS;
    int32_t result=r07_tos(a,4);
    if(result!=-46)return result;
    return r26_set_current(d)?(int32_t)r03_drive_bits():result;
}
